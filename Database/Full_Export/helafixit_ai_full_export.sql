-- phpMyAdmin SQL Dump
-- version 5.2.1
-- https://www.phpmyadmin.net/
--
-- Host: 127.0.0.1
-- Generation Time: Aug 30, 2026 at 09:03 PM
-- Server version: 10.4.32-MariaDB
-- PHP Version: 8.2.12

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `helafixit_ai`
--

DELIMITER $$
--
-- Procedures
--
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_assign_ticket` (IN `p_ticket_id` BIGINT UNSIGNED, IN `p_technician_id` BIGINT UNSIGNED, IN `p_prediction_id` BIGINT UNSIGNED, IN `p_assignment_method` VARCHAR(30), IN `p_assigned_by` BIGINT UNSIGNED, IN `p_assignment_score` DECIMAL(5,2), IN `p_reason` VARCHAR(1000))   BEGIN
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

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_change_ticket_status` (IN `p_ticket_id` BIGINT UNSIGNED, IN `p_updated_by` BIGINT UNSIGNED, IN `p_new_status` VARCHAR(30), IN `p_note` TEXT)   BEGIN
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

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_mark_notification_read` (IN `p_notification_id` BIGINT UNSIGNED, IN `p_user_id` BIGINT UNSIGNED)   BEGIN
    UPDATE notifications
    SET read_at = CURRENT_TIMESTAMP,
        delivery_status = 'Read'
    WHERE notification_id = p_notification_id
      AND user_id = p_user_id;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_recalculate_technician_workload` ()   BEGIN
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

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_record_ai_correction` (IN `p_prediction_id` BIGINT UNSIGNED, IN `p_corrected_by` BIGINT UNSIGNED, IN `p_category_id` BIGINT UNSIGNED, IN `p_priority` VARCHAR(20), IN `p_risk_score` DECIMAL(5,2), IN `p_risk_level` VARCHAR(20), IN `p_skill_id` BIGINT UNSIGNED, IN `p_technician_id` BIGINT UNSIGNED, IN `p_reason` VARCHAR(1000))   BEGIN
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

DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `ai_corrections`
--

CREATE TABLE `ai_corrections` (
  `correction_id` bigint(20) UNSIGNED NOT NULL,
  `prediction_id` bigint(20) UNSIGNED NOT NULL,
  `corrected_by` bigint(20) UNSIGNED NOT NULL,
  `corrected_category_id` bigint(20) UNSIGNED DEFAULT NULL,
  `corrected_priority` enum('Emergency','High','Medium','Low') DEFAULT NULL,
  `corrected_risk_score` decimal(5,2) DEFAULT NULL,
  `corrected_risk_level` enum('Low','Medium','High','Critical') DEFAULT NULL,
  `corrected_skill_id` bigint(20) UNSIGNED DEFAULT NULL,
  `corrected_technician_id` bigint(20) UNSIGNED DEFAULT NULL,
  `reason` varchar(1000) NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ;

-- --------------------------------------------------------

--
-- Table structure for table `ai_predictions`
--

CREATE TABLE `ai_predictions` (
  `prediction_id` bigint(20) UNSIGNED NOT NULL,
  `ticket_id` bigint(20) UNSIGNED NOT NULL,
  `model_version_id` bigint(20) UNSIGNED DEFAULT NULL,
  `predicted_category_id` bigint(20) UNSIGNED DEFAULT NULL,
  `category_confidence` decimal(6,5) DEFAULT NULL,
  `predicted_priority` enum('Emergency','High','Medium','Low') NOT NULL,
  `priority_confidence` decimal(6,5) DEFAULT NULL,
  `risk_score` decimal(5,2) NOT NULL,
  `risk_level` enum('Low','Medium','High','Critical') NOT NULL,
  `risk_factors` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`risk_factors`)),
  `safety_flag` tinyint(1) NOT NULL DEFAULT 0,
  `safety_warning` varchar(1000) DEFAULT NULL,
  `safety_trigger_codes` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`safety_trigger_codes`)),
  `duplicate_flag` tinyint(1) NOT NULL DEFAULT 0,
  `duplicate_ticket_id` bigint(20) UNSIGNED DEFAULT NULL,
  `duplicate_similarity` decimal(6,5) DEFAULT NULL,
  `recommended_skill_id` bigint(20) UNSIGNED DEFAULT NULL,
  `recommended_technician_id` bigint(20) UNSIGNED DEFAULT NULL,
  `technician_score` decimal(5,2) DEFAULT NULL,
  `auto_assignment_required` tinyint(1) NOT NULL DEFAULT 0,
  `manual_review_required` tinyint(1) NOT NULL DEFAULT 0,
  `review_status` enum('Pending','Accepted','Corrected','Rejected','Auto Accepted') NOT NULL DEFAULT 'Pending',
  `is_current` tinyint(1) NOT NULL DEFAULT 1,
  `rule_version` varchar(40) NOT NULL DEFAULT '1.0.0',
  `processing_time_ms` int(10) UNSIGNED DEFAULT NULL,
  `processed_at` datetime NOT NULL DEFAULT current_timestamp(),
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ;

--
-- Dumping data for table `ai_predictions`
--

INSERT INTO `ai_predictions` (`prediction_id`, `ticket_id`, `model_version_id`, `predicted_category_id`, `category_confidence`, `predicted_priority`, `priority_confidence`, `risk_score`, `risk_level`, `risk_factors`, `safety_flag`, `safety_warning`, `safety_trigger_codes`, `duplicate_flag`, `duplicate_ticket_id`, `duplicate_similarity`, `recommended_skill_id`, `recommended_technician_id`, `technician_score`, `auto_assignment_required`, `manual_review_required`, `review_status`, `is_current`, `rule_version`, `processing_time_ms`, `processed_at`, `created_at`) VALUES
(95, 65, 19, 8, 0.71000, 'Low', 0.69000, 24.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12}, {\"factor\": \"Issue category\", \"value\": \"CARP\", \"points\": 4}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 7, 199, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1217, '2026-08-23 14:05:02', '2026-08-23 14:05:02'),
(96, 66, 19, 11, 0.94000, 'Emergency', 0.93000, 97.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"GAS\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}]', 1, 'Possible gas hazard detected. Avoid ignition sources, ventilate if safe and move away from the affected area.', '[\"GAS\"]', 0, NULL, NULL, 10, 185, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1234, '2026-08-23 15:10:02', '2026-08-23 15:10:02'),
(97, 67, 19, 2, 0.94000, 'Medium', 0.93000, 38.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"PLUMB\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 2, 157, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1251, '2026-08-23 08:15:02', '2026-08-23 08:15:02'),
(98, 68, 19, 4, 0.94000, 'Medium', 0.93000, 44.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"AC\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 4, 163, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1268, '2026-08-22 14:20:02', '2026-08-22 14:20:02'),
(99, 69, 19, 1, 0.94000, 'High', 0.93000, 76.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"ELEC\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}]', 1, 'Possible electrical hazard detected. Keep away from wet or sparking electrical equipment.', '[\"ELEC\"]', 0, NULL, NULL, 1, 207, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1285, '2026-08-21 13:10:02', '2026-08-21 13:10:02'),
(100, 70, 19, 7, 0.71000, 'Low', 0.69000, 27.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12}, {\"factor\": \"Issue category\", \"value\": \"PEST\", \"points\": 4}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 6, 184, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1302, '2026-08-23 14:15:02', '2026-08-23 14:15:02'),
(101, 71, 19, 3, 0.94000, 'Emergency', 0.93000, 94.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"LIFT\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}]', 1, 'Possible lift entrapment detected. Do not force the doors and wait for trained assistance.', '[\"LIFT\"]', 0, NULL, NULL, 3, 198, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1319, '2026-08-23 15:20:02', '2026-08-23 15:20:02'),
(102, 72, 19, 13, 0.94000, 'High', 0.93000, 63.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"SEC\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 12, 177, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1336, '2026-08-23 08:25:02', '2026-08-23 08:25:02'),
(103, 73, 19, 5, 0.94000, 'High', 0.93000, 72.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"DRAIN\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}]', 1, 'Safety related wording was detected. Follow the displayed precaution and wait for maintenance assistance.', '[\"DRAIN\"]', 0, NULL, NULL, 2, 211, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1353, '2026-08-22 14:35:02', '2026-08-22 14:35:02'),
(104, 74, 19, 6, 0.94000, 'Low', 0.93000, 29.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12}, {\"factor\": \"Issue category\", \"value\": \"CLEAN\", \"points\": 4}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}]', 1, 'Safety related wording was detected. Follow the displayed precaution and wait for maintenance assistance.', '[\"CLEAN\"]', 0, NULL, NULL, 5, 203, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1370, '2026-08-21 13:25:02', '2026-08-21 13:25:02'),
(105, 75, 19, 12, 0.71000, 'High', 0.69000, 62.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"STRUCT\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 11, 193, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1387, '2026-08-23 14:25:02', '2026-08-23 14:25:02'),
(106, 76, 19, 10, 0.94000, 'Emergency', 0.93000, 100.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"FIRE\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}]', 1, 'Possible fire or smoke hazard detected. Keep away from the source and follow building emergency procedures.', '[\"FIRE\"]', 0, NULL, NULL, 9, 189, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1404, '2026-08-23 15:30:02', '2026-08-23 15:30:02'),
(107, 77, 19, 8, 0.94000, 'Low', 0.93000, 31.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12}, {\"factor\": \"Issue category\", \"value\": \"CARP\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 7, 182, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1421, '2026-08-23 08:35:02', '2026-08-23 08:35:02'),
(108, 78, 19, 2, 0.94000, 'Medium', 0.93000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"PLUMB\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 2, 156, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1438, '2026-08-22 14:50:02', '2026-08-22 14:50:02'),
(109, 79, 19, 4, 0.94000, 'Medium', 0.93000, 36.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"AC\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 4, 169, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1455, '2026-08-21 13:40:02', '2026-08-21 13:40:02'),
(110, 80, 19, 9, 0.71000, 'Medium', 0.69000, 41.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"OTHER\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 8, 159, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1472, '2026-08-23 14:35:02', '2026-08-23 14:35:02'),
(111, 81, 19, 1, 0.94000, 'Emergency', 0.93000, 96.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"ELEC\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}]', 1, 'Possible electrical hazard detected. Keep away from wet or sparking electrical equipment.', '[\"ELEC\"]', 0, NULL, NULL, 1, 204, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1489, '2026-08-23 15:40:02', '2026-08-23 15:40:02'),
(112, 82, 19, 6, 0.94000, 'Low', 0.93000, 21.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12}, {\"factor\": \"Issue category\", \"value\": \"CLEAN\", \"points\": 4}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 5, 216, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1506, '2026-08-23 08:45:02', '2026-08-23 08:45:02'),
(113, 83, 19, 7, 0.94000, 'Medium', 0.93000, 39.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"PEST\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 6, 154, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1523, '2026-08-22 15:05:02', '2026-08-22 15:05:02'),
(114, 84, 19, 12, 0.94000, 'High', 0.93000, 68.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"STRUCT\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 11, 166, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1540, '2026-08-21 13:55:02', '2026-08-21 13:55:02'),
(115, 85, 19, 3, 0.71000, 'High', 0.69000, 58.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"LIFT\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 3, 175, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1557, '2026-08-23 14:45:02', '2026-08-23 14:45:02'),
(116, 86, 19, 11, 0.94000, 'Emergency', 0.93000, 99.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"GAS\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}]', 1, 'Possible gas hazard detected. Avoid ignition sources, ventilate if safe and move away from the affected area.', '[\"GAS\"]', 0, NULL, NULL, 10, 202, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1574, '2026-08-23 15:50:02', '2026-08-23 15:50:02'),
(117, 87, 19, 1, 0.94000, 'High', 0.93000, 59.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"ELEC\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 1, 170, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1591, '2026-08-23 08:55:02', '2026-08-23 08:55:02'),
(118, 88, 19, 13, 0.94000, 'High', 0.93000, 57.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"SEC\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 12, 212, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1608, '2026-08-22 15:20:02', '2026-08-22 15:20:02'),
(119, 89, 19, 2, 0.94000, 'Medium', 0.93000, 35.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"PLUMB\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 2, 172, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1625, '2026-08-21 14:10:02', '2026-08-21 14:10:02'),
(120, 90, 19, 9, 0.71000, 'Medium', 0.69000, 46.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"OTHER\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 8, 153, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1642, '2026-08-20 10:20:02', '2026-08-20 10:20:02'),
(121, 91, 19, 10, 0.94000, 'Emergency', 0.93000, 98.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"FIRE\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}]', 1, 'Possible fire or smoke hazard detected. Keep away from the source and follow building emergency procedures.', '[\"FIRE\"]', 0, NULL, NULL, 9, 162, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1659, '2026-08-20 11:15:02', '2026-08-20 11:15:02'),
(122, 92, 19, 5, 0.94000, 'High', 0.93000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"DRAIN\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 2, 183, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1676, '2026-08-20 09:10:02', '2026-08-20 09:10:02'),
(126, 96, 19, 2, 0.76000, 'Medium', 0.74000, 46.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"PLUMB\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Sinhala\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 2, 157, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1217, '2026-08-23 13:00:02', '2026-08-23 13:00:02'),
(127, 97, 19, 1, 0.76000, 'Low', 0.74000, 28.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12}, {\"factor\": \"Issue category\", \"value\": \"ELEC\", \"points\": 4}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Singlish\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 1, 207, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1234, '2026-08-23 13:17:02', '2026-08-23 13:17:02'),
(128, 98, 19, 4, 0.70000, 'Medium', 0.68000, 42.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"AC\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Mixed\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 4, 163, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1251, '2026-08-23 13:34:02', '2026-08-23 13:34:02'),
(129, 99, 19, 13, 0.76000, 'Medium', 0.74000, 51.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"SEC\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"English\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 12, 178, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1268, '2026-08-23 13:51:02', '2026-08-23 13:51:02'),
(130, 100, 19, 5, 0.76000, 'Medium', 0.74000, 39.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"DRAIN\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Sinhala\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 2, 173, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1285, '2026-08-23 14:08:02', '2026-08-23 14:08:02'),
(131, 101, 19, 8, 0.76000, 'Low', 0.74000, 22.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12}, {\"factor\": \"Issue category\", \"value\": \"CARP\", \"points\": 4}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Singlish\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 7, 199, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1302, '2026-08-23 14:25:02', '2026-08-23 14:25:02'),
(132, 102, 19, 7, 0.70000, 'Low', 0.68000, 25.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12}, {\"factor\": \"Issue category\", \"value\": \"PEST\", \"points\": 4}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Mixed\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 6, 181, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1319, '2026-08-23 14:42:02', '2026-08-23 14:42:02'),
(133, 103, 19, 3, 0.76000, 'Medium', 0.74000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"LIFT\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"English\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 3, 198, 95.00, 0, 1, 'Pending', 1, '6.0.0', 1336, '2026-08-23 14:59:02', '2026-08-23 14:59:02'),
(134, 104, 19, 10, 0.90000, 'Emergency', 0.89000, 96.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"FIRE\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Sinhala\", \"points\": 0}]', 1, 'Possible fire or smoke hazard detected. Keep away from the source and follow building emergency procedures.', '[\"FIRE\"]', 0, NULL, NULL, 9, 187, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1353, '2026-08-23 17:00:02', '2026-08-23 17:00:02'),
(135, 105, 19, 11, 0.88000, 'Emergency', 0.87000, 98.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"GAS\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Singlish\", \"points\": 0}]', 1, 'Possible gas hazard detected. Avoid ignition sources, ventilate if safe and move away from the affected area.', '[\"GAS\"]', 0, NULL, NULL, 10, 161, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1370, '2026-08-23 17:17:02', '2026-08-23 17:17:02'),
(136, 106, 19, 1, 0.85000, 'Emergency', 0.84000, 99.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"ELEC\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Mixed\", \"points\": 0}]', 1, 'Possible electrical hazard detected. Keep away from wet or sparking electrical equipment.', '[\"ELEC\"]', 0, NULL, NULL, 1, 167, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1387, '2026-08-23 17:34:02', '2026-08-23 17:34:02'),
(137, 107, 19, 12, 0.96000, 'Emergency', 0.95000, 93.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"STRUCT\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"English\", \"points\": 0}]', 1, 'Safety related wording was detected. Follow the displayed precaution and wait for maintenance assistance.', '[\"STRUCT\"]', 0, NULL, NULL, 11, 164, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1404, '2026-08-23 17:51:02', '2026-08-23 17:51:02'),
(138, 108, 19, 2, 0.90000, 'Emergency', 0.89000, 95.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"PLUMB\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Sinhala\", \"points\": 0}]', 1, 'Safety related wording was detected. Follow the displayed precaution and wait for maintenance assistance.', '[\"PLUMB\"]', 0, NULL, NULL, 2, 201, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1421, '2026-08-23 18:08:02', '2026-08-23 18:08:02'),
(139, 109, 19, 4, 0.88000, 'Emergency', 0.87000, 94.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"AC\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Singlish\", \"points\": 0}]', 1, 'Safety related wording was detected. Follow the displayed precaution and wait for maintenance assistance.', '[\"AC\"]', 0, NULL, NULL, 4, 160, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1438, '2026-08-23 18:25:02', '2026-08-23 18:25:02'),
(140, 110, 19, 13, 0.85000, 'Emergency', 0.84000, 91.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"SEC\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Mixed\", \"points\": 0}]', 1, 'Safety related wording was detected. Follow the displayed precaution and wait for maintenance assistance.', '[\"SEC\"]', 0, NULL, NULL, 12, 177, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1455, '2026-08-23 18:42:02', '2026-08-23 18:42:02'),
(141, 118, 19, 8, 0.85000, 'Low', 0.84000, 29.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12}, {\"factor\": \"Issue category\", \"value\": \"CARP\", \"points\": 4}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Mixed\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 7, 182, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1591, '2026-08-22 09:42:02', '2026-08-22 09:42:02'),
(142, 111, 19, 6, 0.96000, 'Emergency', 0.95000, 89.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68}, {\"factor\": \"Issue category\", \"value\": \"CLEAN\", \"points\": 20}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"English\", \"points\": 0}]', 1, 'Safety related wording was detected. Follow the displayed precaution and wait for maintenance assistance.', '[\"CLEAN\"]', 0, NULL, NULL, 5, 176, 95.00, 1, 0, 'Pending', 1, '6.0.0', 1472, '2026-08-23 18:59:02', '2026-08-23 18:59:02'),
(143, 112, 19, 3, 0.90000, 'High', 0.89000, 72.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"LIFT\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Sinhala\", \"points\": 0}]', 1, 'Possible lift entrapment detected. Do not force the doors and wait for trained assistance.', '[\"LIFT\"]', 0, NULL, NULL, 3, 158, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1489, '2026-08-22 08:00:02', '2026-08-22 08:00:02'),
(144, 113, 19, 5, 0.88000, 'High', 0.87000, 78.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"DRAIN\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Singlish\", \"points\": 0}]', 1, 'Safety related wording was detected. Follow the displayed precaution and wait for maintenance assistance.', '[\"DRAIN\"]', 0, NULL, NULL, 2, 171, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1506, '2026-08-22 08:17:02', '2026-08-22 08:17:02'),
(145, 114, 19, 10, 0.85000, 'High', 0.84000, 74.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"FIRE\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Mixed\", \"points\": 0}]', 1, 'Possible fire or smoke hazard detected. Keep away from the source and follow building emergency procedures.', '[\"FIRE\"]', 0, NULL, NULL, 9, 189, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1523, '2026-08-22 08:34:02', '2026-08-22 08:34:02'),
(146, 115, 19, 1, 0.96000, 'High', 0.95000, 68.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"ELEC\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"English\", \"points\": 0}]', 1, 'Possible electrical hazard detected. Keep away from wet or sparking electrical equipment.', '[\"ELEC\"]', 0, NULL, NULL, 1, 152, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1540, '2026-08-22 08:51:02', '2026-08-22 08:51:02'),
(147, 116, 19, 7, 0.90000, 'Medium', 0.89000, 54.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"PEST\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Sinhala\", \"points\": 0}]', 1, 'Safety related wording was detected. Follow the displayed precaution and wait for maintenance assistance.', '[\"PEST\"]', 0, NULL, NULL, 6, 180, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1557, '2026-08-22 09:08:02', '2026-08-22 09:08:02'),
(148, 117, 19, 9, 0.88000, 'Medium', 0.87000, 43.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"OTHER\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Singlish\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 8, 188, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1574, '2026-08-22 09:25:02', '2026-08-22 09:25:02'),
(149, 119, 19, 2, 0.96000, 'Medium', 0.95000, 38.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"PLUMB\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"English\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 2, 210, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1608, '2026-08-22 09:59:02', '2026-08-22 09:59:02'),
(150, 120, 19, 1, 0.90000, 'Medium', 0.89000, 41.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"ELEC\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Sinhala\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 1, 204, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1625, '2026-08-21 09:00:02', '2026-08-21 09:00:02'),
(151, 121, 19, 13, 0.88000, 'Medium', 0.87000, 37.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"SEC\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Singlish\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 12, 168, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1642, '2026-08-21 09:17:02', '2026-08-21 09:17:02'),
(152, 122, 19, 4, 0.85000, 'Medium', 0.84000, 45.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"AC\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Mixed\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 4, 214, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1659, '2026-08-21 09:34:02', '2026-08-21 09:34:02'),
(153, 123, 19, 12, 0.96000, 'High', 0.95000, 63.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"STRUCT\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"English\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 11, 166, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1676, '2026-08-21 09:51:02', '2026-08-21 09:51:02'),
(154, 124, 19, 6, 0.90000, 'Medium', 0.89000, 35.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"CLEAN\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Sinhala\", \"points\": 0}]', 1, 'Safety related wording was detected. Follow the displayed precaution and wait for maintenance assistance.', '[\"CLEAN\"]', 0, NULL, NULL, 5, 216, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1693, '2026-08-21 10:08:02', '2026-08-21 10:08:02'),
(155, 125, 19, 5, 0.88000, 'Medium', 0.87000, 49.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"DRAIN\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Singlish\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 2, 215, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1710, '2026-08-21 10:25:02', '2026-08-21 10:25:02'),
(156, 126, 19, 3, 0.85000, 'High', 0.84000, 70.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"LIFT\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Mixed\", \"points\": 0}]', 1, 'Possible lift entrapment detected. Do not force the doors and wait for trained assistance.', '[\"LIFT\"]', 0, NULL, NULL, 3, 175, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1727, '2026-08-21 10:42:02', '2026-08-21 10:42:02'),
(157, 127, 19, 11, 0.96000, 'High', 0.95000, 66.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"GAS\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"English\", \"points\": 0}]', 1, 'Possible gas hazard detected. Avoid ignition sources, ventilate if safe and move away from the affected area.', '[\"GAS\"]', 0, NULL, NULL, 10, 202, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1744, '2026-08-18 10:29:02', '2026-08-18 10:29:02'),
(158, 128, 19, 10, 0.90000, 'High', 0.89000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45}, {\"factor\": \"Issue category\", \"value\": \"FIRE\", \"points\": 14}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Sinhala\", \"points\": 0}]', 1, 'Possible fire or smoke hazard detected. Keep away from the source and follow building emergency procedures.', '[\"FIRE\"]', 0, NULL, NULL, 9, 197, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1761, '2026-08-18 08:30:02', '2026-08-18 08:30:02'),
(159, 129, 19, 8, 0.88000, 'Low', 0.87000, 26.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12}, {\"factor\": \"Issue category\", \"value\": \"CARP\", \"points\": 4}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Singlish\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 7, 191, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1778, '2026-08-18 08:47:02', '2026-08-18 08:47:02'),
(160, 130, 19, 2, 0.85000, 'Medium', 0.84000, 44.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"PLUMB\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Mixed\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 2, 172, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1795, '2026-08-18 09:04:02', '2026-08-18 09:04:02'),
(161, 131, 19, 7, 0.96000, 'Medium', 0.95000, 52.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"PEST\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"English\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 6, 190, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1812, '2026-08-18 09:21:02', '2026-08-18 09:21:02'),
(162, 132, 19, 13, 0.90000, 'Medium', 0.89000, 47.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 25}, {\"factor\": \"Issue category\", \"value\": \"SEC\", \"points\": 8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 3}, {\"factor\": \"Language type\", \"value\": \"Sinhala\", \"points\": 0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 12, 212, 95.00, 0, 0, 'Accepted', 1, '6.0.0', 1829, '2026-08-18 09:38:02', '2026-08-18 09:38:02'),
(163, 133, 19, 2, 0.82489, 'High', 0.52798, 53.20, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45.0}, {\"factor\": \"Issue category severity\", \"value\": \"Plumbing\", \"points\": 4.2}, {\"factor\": \"Location context\", \"value\": \"bathroom\", \"points\": 4.0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 2, 171, 99.30, 0, 1, 'Accepted', 1, '6.0.0', 2424, '2026-08-26 18:44:35', '2026-08-26 18:44:35'),
(164, 134, 19, 3, 0.93000, 'High', 0.91000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 12.8}]', 0, NULL, '[]', 0, NULL, NULL, 3, 206, 89.00, 0, 0, 'Pending', 1, '6.0.0', 34, '2026-08-24 08:15:02', '2026-08-24 08:15:02'),
(165, 135, 19, 3, 0.93900, 'High', 0.92000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 12.8}]', 0, NULL, '[]', 1, 134, 0.92000, 3, 206, 90.00, 0, 1, 'Pending', 1, '6.0.0', 35, '2026-08-24 09:28:02', '2026-08-24 09:28:02'),
(166, 136, 19, 2, 0.94800, 'Medium', 0.93000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 9.6}]', 0, NULL, '[]', 0, NULL, NULL, 2, 173, 91.00, 0, 0, 'Pending', 1, '6.0.0', 36, '2026-08-24 10:41:02', '2026-08-24 10:41:02'),
(167, 137, 19, 2, 0.95700, 'Medium', 0.94000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 9.6}]', 0, NULL, '[]', 1, 136, 0.94000, 2, 173, 92.00, 0, 1, 'Pending', 1, '6.0.0', 37, '2026-08-24 11:54:02', '2026-08-24 11:54:02'),
(168, 138, 19, 1, 0.96600, 'High', 0.95000, 68.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 30.6}, {\"factor\": \"Issue category\", \"value\": \"Electrical\", \"points\": 23.8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 13.6}]', 0, NULL, '[]', 0, NULL, NULL, 1, 207, 93.00, 0, 0, 'Pending', 1, '6.0.0', 38, '2026-08-24 13:07:02', '2026-08-24 13:07:02'),
(169, 139, 19, 1, 0.93000, 'High', 0.96000, 68.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 30.6}, {\"factor\": \"Issue category\", \"value\": \"Electrical\", \"points\": 23.8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 13.6}]', 0, NULL, '[]', 1, 138, 0.91000, 1, 207, 94.00, 0, 1, 'Pending', 1, '6.0.0', 39, '2026-08-24 14:20:02', '2026-08-24 14:20:02'),
(170, 140, 19, 8, 0.93900, 'Low', 0.91000, 25.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 11.25}, {\"factor\": \"Issue category\", \"value\": \"Carpentry\", \"points\": 8.75}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 5.0}]', 0, NULL, '[]', 0, NULL, NULL, 7, 199, 95.00, 0, 0, 'Pending', 1, '6.0.0', 40, '2026-08-24 15:33:02', '2026-08-24 15:33:02'),
(171, 141, 19, 13, 0.94800, 'High', 0.92000, 65.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 29.25}, {\"factor\": \"Issue category\", \"value\": \"Security and Access\", \"points\": 22.75}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 13.0}]', 0, NULL, '[]', 0, NULL, NULL, 12, 178, 96.00, 0, 0, 'Pending', 1, '6.0.0', 41, '2026-08-24 16:46:02', '2026-08-24 16:46:02'),
(172, 142, 19, 2, 0.95700, 'Medium', 0.93000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 9.6}]', 0, NULL, '[]', 0, NULL, NULL, 2, 173, 89.00, 0, 0, 'Pending', 1, '6.0.0', 42, '2026-08-24 17:59:02', '2026-08-24 17:59:02'),
(173, 143, 19, 5, 0.96600, 'High', 0.94000, 62.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 27.9}, {\"factor\": \"Issue category\", \"value\": \"Drainage\", \"points\": 21.7}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 12.4}]', 0, NULL, '[]', 0, NULL, NULL, 2, 173, 90.00, 0, 0, 'Pending', 1, '6.0.0', 43, '2026-08-24 19:12:02', '2026-08-24 19:12:02'),
(174, 144, 19, 7, 0.93000, 'Low', 0.95000, 28.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12.6}, {\"factor\": \"Issue category\", \"value\": \"Pest Control\", \"points\": 9.8}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 5.6}]', 0, NULL, '[]', 0, NULL, NULL, 6, 181, 91.00, 0, 0, 'Pending', 1, '6.0.0', 44, '2026-08-24 20:25:02', '2026-08-24 20:25:02'),
(175, 145, 19, 9, 0.93900, 'Medium', 0.96000, 38.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 17.1}, {\"factor\": \"Issue category\", \"value\": \"Other\", \"points\": 13.3}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 7.6}]', 0, NULL, '[]', 0, NULL, NULL, 8, 153, 92.00, 0, 0, 'Pending', 1, '6.0.0', 45, '2026-08-24 21:38:02', '2026-08-24 21:38:02'),
(176, 146, 19, 13, 0.94800, 'High', 0.91000, 65.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 29.25}, {\"factor\": \"Issue category\", \"value\": \"Security and Access\", \"points\": 22.75}, {\"factor\": \"Location context\", \"value\": \"Block A\", \"points\": 13.0}]', 0, NULL, '[]', 0, NULL, NULL, 12, 178, 93.00, 0, 0, 'Pending', 1, '6.0.0', 46, '2026-08-24 22:51:02', '2026-08-24 22:51:02'),
(177, 147, 19, 3, 0.95700, 'High', 0.92000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 12.8}]', 0, NULL, '[]', 0, NULL, NULL, 3, 198, 94.00, 0, 0, 'Pending', 1, '6.0.0', 47, '2026-08-25 00:04:02', '2026-08-25 00:04:02'),
(178, 148, 19, 3, 0.96600, 'High', 0.93000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 12.8}]', 0, NULL, '[]', 1, 147, 0.95000, 3, 198, 95.00, 0, 1, 'Pending', 1, '6.0.0', 48, '2026-08-25 01:17:02', '2026-08-25 01:17:02'),
(179, 149, 19, 2, 0.93000, 'Medium', 0.94000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 9.6}]', 0, NULL, '[]', 0, NULL, NULL, 2, 201, 96.00, 0, 0, 'Pending', 1, '6.0.0', 49, '2026-08-25 02:30:02', '2026-08-25 02:30:02'),
(180, 150, 19, 2, 0.93900, 'Medium', 0.95000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 9.6}]', 0, NULL, '[]', 1, 149, 0.92000, 2, 201, 89.00, 0, 1, 'Pending', 1, '6.0.0', 50, '2026-08-25 03:43:02', '2026-08-25 03:43:02'),
(181, 151, 19, 1, 0.94800, 'High', 0.96000, 68.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 30.6}, {\"factor\": \"Issue category\", \"value\": \"Electrical\", \"points\": 23.8}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 13.6}]', 0, NULL, '[]', 0, NULL, NULL, 1, 167, 90.00, 0, 0, 'Pending', 1, '6.0.0', 51, '2026-08-25 04:56:02', '2026-08-25 04:56:02'),
(182, 152, 19, 1, 0.95700, 'High', 0.91000, 68.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 30.6}, {\"factor\": \"Issue category\", \"value\": \"Electrical\", \"points\": 23.8}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 13.6}]', 0, NULL, '[]', 1, 151, 0.94000, 1, 167, 91.00, 0, 1, 'Pending', 1, '6.0.0', 52, '2026-08-25 06:09:02', '2026-08-25 06:09:02'),
(183, 153, 19, 7, 0.96600, 'Low', 0.92000, 28.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12.6}, {\"factor\": \"Issue category\", \"value\": \"Pest Control\", \"points\": 9.8}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 5.6}]', 0, NULL, '[]', 0, NULL, NULL, 6, 184, 92.00, 0, 0, 'Pending', 1, '6.0.0', 34, '2026-08-25 07:22:02', '2026-08-25 07:22:02'),
(184, 154, 19, 13, 0.93000, 'High', 0.93000, 65.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 29.25}, {\"factor\": \"Issue category\", \"value\": \"Security and Access\", \"points\": 22.75}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 13.0}]', 0, NULL, '[]', 0, NULL, NULL, 12, 177, 93.00, 0, 0, 'Pending', 1, '6.0.0', 35, '2026-08-25 08:35:02', '2026-08-25 08:35:02'),
(185, 155, 19, 12, 0.93900, 'High', 0.94000, 72.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 32.4}, {\"factor\": \"Issue category\", \"value\": \"Structural\", \"points\": 25.2}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 14.4}]', 0, NULL, '[]', 0, NULL, NULL, 11, 164, 94.00, 0, 0, 'Pending', 1, '6.0.0', 36, '2026-08-25 09:48:02', '2026-08-25 09:48:02'),
(186, 156, 19, 3, 0.94800, 'High', 0.95000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 12.8}]', 0, NULL, '[]', 0, NULL, NULL, 3, 198, 95.00, 0, 0, 'Pending', 1, '6.0.0', 37, '2026-08-25 11:01:02', '2026-08-25 11:01:02'),
(187, 157, 19, 2, 0.95700, 'Medium', 0.96000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 9.6}]', 0, NULL, '[]', 0, NULL, NULL, 2, 201, 96.00, 0, 0, 'Pending', 1, '6.0.0', 38, '2026-08-25 12:14:02', '2026-08-25 12:14:02'),
(188, 158, 19, 5, 0.96600, 'High', 0.91000, 62.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 27.9}, {\"factor\": \"Issue category\", \"value\": \"Drainage\", \"points\": 21.7}, {\"factor\": \"Location context\", \"value\": \"Block B\", \"points\": 12.4}]', 0, NULL, '[]', 0, NULL, NULL, 2, 201, 89.00, 0, 0, 'Pending', 1, '6.0.0', 39, '2026-08-25 13:27:02', '2026-08-25 13:27:02'),
(189, 159, 19, 3, 0.93000, 'High', 0.92000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 12.8}]', 0, NULL, '[]', 0, NULL, NULL, 3, 158, 90.00, 0, 0, 'Pending', 1, '6.0.0', 40, '2026-08-25 14:40:02', '2026-08-25 14:40:02'),
(190, 160, 19, 3, 0.93900, 'High', 0.93000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 12.8}]', 0, NULL, '[]', 1, 159, 0.92000, 3, 158, 91.00, 0, 1, 'Pending', 1, '6.0.0', 41, '2026-08-25 15:53:02', '2026-08-25 15:53:02'),
(191, 161, 19, 2, 0.94800, 'Medium', 0.94000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 9.6}]', 0, NULL, '[]', 0, NULL, NULL, 2, 171, 92.00, 0, 0, 'Pending', 1, '6.0.0', 42, '2026-08-25 17:06:02', '2026-08-25 17:06:02'),
(192, 162, 19, 2, 0.95700, 'Medium', 0.95000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 9.6}]', 0, NULL, '[]', 1, 161, 0.94000, 2, 171, 93.00, 0, 1, 'Pending', 1, '6.0.0', 43, '2026-08-25 18:19:02', '2026-08-25 18:19:02'),
(193, 163, 19, 1, 0.96600, 'High', 0.96000, 68.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 30.6}, {\"factor\": \"Issue category\", \"value\": \"Electrical\", \"points\": 23.8}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 13.6}]', 0, NULL, '[]', 0, NULL, NULL, 1, 152, 94.00, 0, 0, 'Pending', 1, '6.0.0', 44, '2026-08-25 19:32:02', '2026-08-25 19:32:02');
INSERT INTO `ai_predictions` (`prediction_id`, `ticket_id`, `model_version_id`, `predicted_category_id`, `category_confidence`, `predicted_priority`, `priority_confidence`, `risk_score`, `risk_level`, `risk_factors`, `safety_flag`, `safety_warning`, `safety_trigger_codes`, `duplicate_flag`, `duplicate_ticket_id`, `duplicate_similarity`, `recommended_skill_id`, `recommended_technician_id`, `technician_score`, `auto_assignment_required`, `manual_review_required`, `review_status`, `is_current`, `rule_version`, `processing_time_ms`, `processed_at`, `created_at`) VALUES
(194, 164, 19, 1, 0.93000, 'High', 0.91000, 68.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 30.6}, {\"factor\": \"Issue category\", \"value\": \"Electrical\", \"points\": 23.8}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 13.6}]', 0, NULL, '[]', 1, 163, 0.91000, 1, 152, 95.00, 0, 1, 'Pending', 1, '6.0.0', 45, '2026-08-25 20:45:02', '2026-08-25 20:45:02'),
(195, 165, 19, 12, 0.93900, 'High', 0.92000, 72.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 32.4}, {\"factor\": \"Issue category\", \"value\": \"Structural\", \"points\": 25.2}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 14.4}]', 0, NULL, '[]', 0, NULL, NULL, 11, 193, 96.00, 0, 0, 'Pending', 1, '6.0.0', 46, '2026-08-25 21:58:02', '2026-08-25 21:58:02'),
(196, 166, 19, 2, 0.94800, 'Medium', 0.93000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 9.6}]', 0, NULL, '[]', 0, NULL, NULL, 2, 171, 89.00, 0, 0, 'Pending', 1, '6.0.0', 47, '2026-08-25 23:11:02', '2026-08-25 23:11:02'),
(197, 167, 19, 4, 0.95700, 'Medium', 0.94000, 42.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 18.9}, {\"factor\": \"Issue category\", \"value\": \"Air Conditioning\", \"points\": 14.7}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 8.4}]', 0, NULL, '[]', 0, NULL, NULL, 4, 169, 90.00, 0, 0, 'Pending', 1, '6.0.0', 48, '2026-08-26 00:24:02', '2026-08-26 00:24:02'),
(198, 168, 19, 6, 0.96600, 'Low', 0.95000, 22.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 9.9}, {\"factor\": \"Issue category\", \"value\": \"Cleaning\", \"points\": 7.7}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 4.4}]', 0, NULL, '[]', 0, NULL, NULL, 5, 176, 91.00, 0, 0, 'Pending', 1, '6.0.0', 49, '2026-08-26 01:37:02', '2026-08-26 01:37:02'),
(199, 169, 19, 8, 0.93000, 'Low', 0.96000, 25.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 11.25}, {\"factor\": \"Issue category\", \"value\": \"Carpentry\", \"points\": 8.75}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 5.0}]', 0, NULL, '[]', 0, NULL, NULL, 7, 182, 92.00, 0, 0, 'Pending', 1, '6.0.0', 50, '2026-08-26 02:50:02', '2026-08-26 02:50:02'),
(200, 170, 19, 12, 0.93900, 'High', 0.91000, 72.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 32.4}, {\"factor\": \"Issue category\", \"value\": \"Structural\", \"points\": 25.2}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 14.4}]', 0, NULL, '[]', 0, NULL, NULL, 11, 193, 93.00, 0, 0, 'Pending', 1, '6.0.0', 51, '2026-08-26 04:03:02', '2026-08-26 04:03:02'),
(201, 171, 19, 3, 0.94800, 'High', 0.92000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block C\", \"points\": 12.8}]', 0, NULL, '[]', 0, NULL, NULL, 3, 158, 94.00, 0, 0, 'Pending', 1, '6.0.0', 52, '2026-08-26 05:16:02', '2026-08-26 05:16:02'),
(202, 172, 19, 3, 0.95700, 'High', 0.93000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 12.8}]', 0, NULL, '[]', 0, NULL, NULL, 3, 213, 95.00, 0, 0, 'Pending', 1, '6.0.0', 34, '2026-08-26 06:29:02', '2026-08-26 06:29:02'),
(203, 173, 19, 3, 0.96600, 'High', 0.94000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 12.8}]', 0, NULL, '[]', 1, 172, 0.95000, 3, 213, 96.00, 0, 1, 'Pending', 1, '6.0.0', 35, '2026-08-26 07:42:02', '2026-08-26 07:42:02'),
(204, 174, 19, 2, 0.93000, 'Medium', 0.95000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 9.6}]', 0, NULL, '[]', 0, NULL, NULL, 2, 215, 89.00, 0, 0, 'Pending', 1, '6.0.0', 36, '2026-08-26 08:55:02', '2026-08-26 08:55:02'),
(205, 175, 19, 2, 0.93900, 'Medium', 0.96000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 9.6}]', 0, NULL, '[]', 1, 174, 0.92000, 2, 215, 90.00, 0, 1, 'Pending', 1, '6.0.0', 37, '2026-08-26 10:08:02', '2026-08-26 10:08:02'),
(206, 176, 19, 1, 0.94800, 'High', 0.91000, 68.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 30.6}, {\"factor\": \"Issue category\", \"value\": \"Electrical\", \"points\": 23.8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 13.6}]', 0, NULL, '[]', 0, NULL, NULL, 1, 204, 91.00, 0, 0, 'Pending', 1, '6.0.0', 38, '2026-08-26 11:21:02', '2026-08-26 11:21:02'),
(207, 177, 19, 1, 0.95700, 'High', 0.92000, 68.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 30.6}, {\"factor\": \"Issue category\", \"value\": \"Electrical\", \"points\": 23.8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 13.6}]', 0, NULL, '[]', 1, 176, 0.94000, 1, 204, 92.00, 0, 1, 'Pending', 1, '6.0.0', 39, '2026-08-26 12:34:02', '2026-08-26 12:34:02'),
(208, 178, 19, 5, 0.96600, 'High', 0.93000, 62.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 27.9}, {\"factor\": \"Issue category\", \"value\": \"Drainage\", \"points\": 21.7}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 12.4}]', 0, NULL, '[]', 0, NULL, NULL, 2, 215, 93.00, 0, 0, 'Pending', 1, '6.0.0', 40, '2026-08-26 13:47:02', '2026-08-26 13:47:02'),
(209, 179, 19, 12, 0.93000, 'High', 0.94000, 72.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 32.4}, {\"factor\": \"Issue category\", \"value\": \"Structural\", \"points\": 25.2}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 14.4}]', 0, NULL, '[]', 0, NULL, NULL, 11, 166, 94.00, 0, 0, 'Pending', 1, '6.0.0', 41, '2026-08-26 15:00:02', '2026-08-26 15:00:02'),
(210, 180, 19, 3, 0.93900, 'High', 0.95000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 12.8}]', 0, NULL, '[]', 0, NULL, NULL, 3, 213, 95.00, 0, 0, 'Pending', 1, '6.0.0', 42, '2026-08-26 16:13:02', '2026-08-26 16:13:02'),
(211, 181, 19, 2, 0.94800, 'Medium', 0.96000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 9.6}]', 0, NULL, '[]', 0, NULL, NULL, 2, 215, 96.00, 0, 0, 'Pending', 1, '6.0.0', 43, '2026-08-26 17:26:02', '2026-08-26 17:26:02'),
(212, 182, 19, 5, 0.95700, 'High', 0.91000, 62.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 27.9}, {\"factor\": \"Issue category\", \"value\": \"Drainage\", \"points\": 21.7}, {\"factor\": \"Location context\", \"value\": \"Block D\", \"points\": 12.4}]', 0, NULL, '[]', 0, NULL, NULL, 2, 215, 89.00, 0, 0, 'Pending', 1, '6.0.0', 44, '2026-08-26 18:39:02', '2026-08-26 18:39:02'),
(213, 183, 19, 3, 0.96600, 'High', 0.92000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 12.8}]', 0, NULL, '[]', 0, NULL, NULL, 3, 175, 90.00, 0, 0, 'Pending', 1, '6.0.0', 45, '2026-08-26 19:52:02', '2026-08-26 19:52:02'),
(214, 184, 19, 3, 0.93000, 'High', 0.93000, 64.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 28.8}, {\"factor\": \"Issue category\", \"value\": \"Lift\", \"points\": 22.4}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 12.8}]', 0, NULL, '[]', 1, 183, 0.91000, 3, 175, 91.00, 0, 1, 'Pending', 1, '6.0.0', 46, '2026-08-26 21:05:02', '2026-08-26 21:05:02'),
(215, 185, 19, 2, 0.93900, 'Medium', 0.94000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 9.6}]', 0, NULL, '[]', 0, NULL, NULL, 2, 172, 92.00, 0, 0, 'Pending', 1, '6.0.0', 47, '2026-08-26 22:18:02', '2026-08-26 22:18:02'),
(216, 186, 19, 2, 0.94800, 'Medium', 0.95000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 9.6}]', 0, NULL, '[]', 1, 185, 0.93000, 2, 172, 93.00, 0, 1, 'Pending', 1, '6.0.0', 48, '2026-08-26 23:31:02', '2026-08-26 23:31:02'),
(217, 187, 19, 1, 0.95700, 'High', 0.96000, 68.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 30.6}, {\"factor\": \"Issue category\", \"value\": \"Electrical\", \"points\": 23.8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 13.6}]', 0, NULL, '[]', 0, NULL, NULL, 1, 170, 94.00, 0, 0, 'Pending', 1, '6.0.0', 49, '2026-08-27 00:44:02', '2026-08-27 00:44:02'),
(218, 188, 19, 1, 0.96600, 'High', 0.91000, 68.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 30.6}, {\"factor\": \"Issue category\", \"value\": \"Electrical\", \"points\": 23.8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 13.6}]', 0, NULL, '[]', 1, 187, 0.95000, 1, 170, 95.00, 0, 1, 'Pending', 1, '6.0.0', 50, '2026-08-27 01:57:02', '2026-08-27 01:57:02'),
(219, 189, 19, 2, 0.93000, 'Medium', 0.92000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 9.6}]', 0, NULL, '[]', 0, NULL, NULL, 2, 172, 96.00, 0, 0, 'Pending', 1, '6.0.0', 51, '2026-08-27 03:10:02', '2026-08-27 03:10:02'),
(220, 190, 19, 2, 0.93900, 'Medium', 0.93000, 48.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 21.6}, {\"factor\": \"Issue category\", \"value\": \"Plumbing\", \"points\": 16.8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 9.6}]', 0, NULL, '[]', 0, NULL, NULL, 2, 172, 89.00, 0, 0, 'Pending', 1, '6.0.0', 52, '2026-08-27 04:23:02', '2026-08-27 04:23:02'),
(221, 191, 19, 5, 0.94800, 'High', 0.94000, 62.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 27.9}, {\"factor\": \"Issue category\", \"value\": \"Drainage\", \"points\": 21.7}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 12.4}]', 0, NULL, '[]', 0, NULL, NULL, 2, 172, 90.00, 0, 0, 'Pending', 1, '6.0.0', 34, '2026-08-27 05:36:02', '2026-08-27 05:36:02'),
(222, 192, 19, 7, 0.95700, 'Low', 0.95000, 28.00, 'Low', '[{\"factor\": \"Predicted priority\", \"value\": \"Low\", \"points\": 12.6}, {\"factor\": \"Issue category\", \"value\": \"Pest Control\", \"points\": 9.8}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 5.6}]', 0, NULL, '[]', 0, NULL, NULL, 6, 190, 91.00, 0, 0, 'Pending', 1, '6.0.0', 35, '2026-08-27 06:49:02', '2026-08-27 06:49:02'),
(223, 193, 19, 9, 0.96600, 'Medium', 0.96000, 38.00, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"Medium\", \"points\": 17.1}, {\"factor\": \"Issue category\", \"value\": \"Other\", \"points\": 13.3}, {\"factor\": \"Location context\", \"value\": \"Block E\", \"points\": 7.6}]', 0, NULL, '[]', 0, NULL, NULL, 8, 195, 92.00, 0, 0, 'Pending', 1, '6.0.0', 36, '2026-08-27 08:02:02', '2026-08-27 08:02:02'),
(224, 194, 19, 2, 0.88238, 'High', 0.84583, 54.70, 'Medium', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45.0}, {\"factor\": \"Issue category severity\", \"value\": \"Plumbing\", \"points\": 4.2}, {\"factor\": \"Location context\", \"value\": \"bathroom\", \"points\": 4.0}, {\"factor\": \"Recent similar issue history\", \"value\": 1, \"points\": 1.5}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 2, 173, 100.00, 0, 0, 'Accepted', 1, '3.0.0', 2488, '2026-08-29 10:31:14', '2026-08-29 10:31:14'),
(225, 195, 19, 1, 0.94109, 'Emergency', 0.97000, 100.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68.0}, {\"factor\": \"Safety hazard wording\", \"value\": [\"SPARK\", \"BURNING_ELECTRICAL\", \"RULE-SPARK-SINGLISH\"], \"points\": 24.0}, {\"factor\": \"Issue category severity\", \"value\": \"Electrical\", \"points\": 7.0}, {\"factor\": \"Location context\", \"value\": \"kitchen\", \"points\": 4.0}, {\"factor\": \"Weekend safety context\", \"value\": \"Saturday\", \"points\": 3.0}]', 1, 'Electrical sparking detected. Do not touch the affected electrical item.', '[\"SPARK\", \"BURNING_ELECTRICAL\", \"RULE-SPARK-SINGLISH\"]', 0, NULL, NULL, 1, 204, 99.68, 1, 1, 'Pending', 1, '3.0.0', 1572, '2026-08-29 11:08:31', '2026-08-29 11:08:31'),
(226, 196, 19, 3, 0.96631, 'High', 0.96916, 62.70, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45.0}, {\"factor\": \"Issue category severity\", \"value\": \"Lift\", \"points\": 7.7}, {\"factor\": \"Location context\", \"value\": \"lift\", \"points\": 7.0}, {\"factor\": \"Recent similar issue history\", \"value\": 2, \"points\": 3.0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 3, 206, 100.00, 0, 0, 'Pending', 0, '3.0.0', 3166, '2026-08-30 00:27:53', '2026-08-30 00:27:53'),
(227, 196, 19, 3, 0.96631, 'High', 0.96916, 62.70, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45.0}, {\"factor\": \"Issue category severity\", \"value\": \"Lift\", \"points\": 7.7}, {\"factor\": \"Location context\", \"value\": \"lift\", \"points\": 7.0}, {\"factor\": \"Recent similar issue history\", \"value\": 2, \"points\": 3.0}]', 0, 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.', '[]', 0, NULL, NULL, 3, 206, 100.00, 0, 0, 'Accepted', 1, '3.0.0', 663, '2026-08-30 00:28:43', '2026-08-30 00:28:43'),
(228, 197, 19, 1, 0.90644, 'Emergency', 0.97000, 100.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68.0}, {\"factor\": \"Safety hazard wording\", \"value\": [\"SHOCK\", \"SPARK\"], \"points\": 24.0}, {\"factor\": \"Issue category severity\", \"value\": \"Electrical\", \"points\": 7.0}, {\"factor\": \"After-hours safety context\", \"value\": \"00:37\", \"points\": 4.0}, {\"factor\": \"Weekend safety context\", \"value\": \"Sunday\", \"points\": 3.0}]', 1, 'Possible electric shock hazard detected. Avoid touching electrical equipment in the affected area.', '[\"SHOCK\", \"SPARK\"]', 0, NULL, NULL, 1, 204, 96.68, 1, 1, 'Pending', 1, '3.0.0', 703, '2026-08-30 00:37:09', '2026-08-30 00:37:09'),
(229, 198, 19, 1, 0.95000, 'Emergency', 0.97000, 100.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68.0}, {\"factor\": \"Safety hazard wording\", \"value\": [\"SHOCK\"], \"points\": 24.0}, {\"factor\": \"Issue category severity\", \"value\": \"Electrical\", \"points\": 7.0}, {\"factor\": \"Location context\", \"value\": \"bathroom\", \"points\": 4.0}, {\"factor\": \"After-hours safety context\", \"value\": \"01:51\", \"points\": 4.0}, {\"factor\": \"Weekend safety context\", \"value\": \"Sunday\", \"points\": 3.0}]', 1, 'Possible electric shock hazard detected. Avoid touching electrical equipment in the affected area.', '[\"SHOCK\"]', 0, NULL, NULL, 1, 167, 100.00, 1, 1, 'Pending', 1, '3.0.0', 1600, '2026-08-30 01:51:18', '2026-08-30 01:51:18'),
(230, 199, 19, 13, 0.95802, 'High', 0.93000, 76.00, 'High', '[{\"factor\": \"Predicted priority\", \"value\": \"High\", \"points\": 45.0}, {\"factor\": \"Safety hazard wording\", \"value\": [\"SECURITY_DOOR_FAILURE\"], \"points\": 17.6}, {\"factor\": \"Issue category severity\", \"value\": \"Security and Access\", \"points\": 6.3}, {\"factor\": \"Weekend safety context\", \"value\": \"Sunday\", \"points\": 3.0}, {\"factor\": \"Safety minimum\", \"value\": [\"SECURITY_DOOR_FAILURE\"], \"points\": 4.1}]', 1, 'The main security door cannot be secured. Arrange urgent repair and inform apartment management.', '[\"SECURITY_DOOR_FAILURE\"]', 0, NULL, NULL, 12, 212, 99.82, 0, 1, 'Accepted', 1, '3.0.0', 2341, '2026-08-30 10:13:47', '2026-08-30 10:13:47'),
(231, 200, 19, 10, 0.90378, 'Emergency', 0.97000, 100.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68.0}, {\"factor\": \"Safety hazard wording\", \"value\": [\"BURNING_ELECTRICAL\"], \"points\": 23.1}, {\"factor\": \"Issue category severity\", \"value\": \"Fire and Safety\", \"points\": 8.0}, {\"factor\": \"Weekend safety context\", \"value\": \"Sunday\", \"points\": 3.0}]', 1, 'A burning smell near electrical equipment may indicate overheating or fire risk.', '[\"BURNING_ELECTRICAL\"]', 0, NULL, NULL, 9, 197, 100.00, 1, 1, 'Pending', 1, '3.0.0', 887, '2026-08-30 10:22:04', '2026-08-30 10:22:04'),
(232, 201, 19, 1, 0.95000, 'Emergency', 0.97000, 100.00, 'Critical', '[{\"factor\": \"Predicted priority\", \"value\": \"Emergency\", \"points\": 68.0}, {\"factor\": \"Safety hazard wording\", \"value\": [\"SPARK\", \"SMOKE\", \"RULE-SMOKE-SI\", \"MAJOR_WATER_LEAK\"], \"points\": 24.0}, {\"factor\": \"Issue category severity\", \"value\": \"Electrical\", \"points\": 7.0}, {\"factor\": \"Weekend safety context\", \"value\": \"Sunday\", \"points\": 3.0}]', 1, 'Electrical sparking detected. Do not touch the affected electrical item.', '[\"SPARK\", \"SMOKE\", \"RULE-SMOKE-SI\", \"MAJOR_WATER_LEAK\"]', 0, NULL, NULL, 1, 204, 93.68, 1, 1, 'Pending', 1, '3.0.0', 2035, '2026-08-30 16:34:18', '2026-08-30 16:34:18');

-- --------------------------------------------------------

--
-- Table structure for table `apartment_admin_profiles`
--

CREATE TABLE `apartment_admin_profiles` (
  `admin_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `primary_building_id` bigint(20) UNSIGNED DEFAULT NULL,
  `job_title` varchar(100) DEFAULT NULL,
  `can_review_emergencies` tinyint(1) NOT NULL DEFAULT 1,
  `active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `apartment_admin_profiles`
--

INSERT INTO `apartment_admin_profiles` (`admin_id`, `user_id`, `primary_building_id`, `job_title`, `can_review_emergencies`, `active`, `created_at`, `updated_at`) VALUES
(22, 335, 1, 'Apartment Administrator', 1, 1, '2026-08-18 09:00:00', '2026-08-18 09:00:00'),
(23, 336, 3, 'Apartment Administrator', 1, 1, '2026-08-18 09:48:00', '2026-08-18 09:48:00'),
(24, 337, 4, 'Apartment Administrator', 1, 1, '2026-08-18 10:12:00', '2026-08-18 10:12:00'),
(25, 338, 7, 'Apartment Administrator', 1, 1, '2026-08-18 10:36:00', '2026-08-18 10:36:00'),
(26, 339, 2, 'Apartment Administrator', 1, 1, '2026-08-18 09:24:00', '2026-08-18 09:24:00'),
(27, 340, 3, 'Assistant Apartment Administrator', 1, 1, '2026-08-18 10:00:00', '2026-08-18 10:00:00'),
(28, 341, 1, 'Assistant Apartment Administrator', 1, 1, '2026-08-18 09:12:00', '2026-08-18 09:12:00'),
(29, 342, 7, 'Assistant Apartment Administrator', 1, 1, '2026-08-18 10:48:00', '2026-08-18 10:48:00'),
(30, 343, 4, 'Assistant Apartment Administrator', 1, 1, '2026-08-18 10:24:00', '2026-08-18 10:24:00'),
(31, 344, 2, 'Assistant Apartment Administrator', 1, 1, '2026-08-18 09:36:00', '2026-08-18 09:36:00');

-- --------------------------------------------------------

--
-- Table structure for table `apartment_complexes`
--

CREATE TABLE `apartment_complexes` (
  `complex_id` bigint(20) UNSIGNED NOT NULL,
  `name` varchar(150) NOT NULL,
  `address_line` varchar(255) DEFAULT NULL,
  `city` varchar(100) NOT NULL DEFAULT 'Colombo',
  `country` varchar(100) NOT NULL DEFAULT 'Sri Lanka',
  `timezone_name` varchar(64) NOT NULL DEFAULT 'Asia/Colombo',
  `status` enum('Active','Inactive') NOT NULL DEFAULT 'Active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `apartment_complexes`
--

INSERT INTO `apartment_complexes` (`complex_id`, `name`, `address_line`, `city`, `country`, `timezone_name`, `status`, `created_at`, `updated_at`) VALUES
(1, 'Hela Residence', NULL, 'Colombo', 'Sri Lanka', 'Asia/Colombo', 'Active', '2026-08-15 13:50:18', '2026-08-27 14:08:00');

-- --------------------------------------------------------

--
-- Table structure for table `areas`
--

CREATE TABLE `areas` (
  `area_id` bigint(20) UNSIGNED NOT NULL,
  `building_id` bigint(20) UNSIGNED NOT NULL,
  `floor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `name` varchar(100) NOT NULL,
  `area_type` enum('Private','Common','Service','Outdoor','Other') NOT NULL DEFAULT 'Common',
  `risk_weight` decimal(5,2) NOT NULL DEFAULT 0.00,
  `status` enum('Active','Inactive') NOT NULL DEFAULT 'Active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ;

--
-- Dumping data for table `areas`
--

INSERT INTO `areas` (`area_id`, `building_id`, `floor_id`, `name`, `area_type`, `risk_weight`, `status`, `created_at`, `updated_at`) VALUES
(1, 1, 2, 'Common Corridor', 'Common', 8.00, 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(2, 1, 2, 'Bathroom', 'Private', 7.00, 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(3, 1, 2, 'Bedroom', 'Private', 2.00, 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(4, 2, 3, 'Lobby', 'Common', 2.00, 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(5, 2, 4, 'Bedroom', 'Private', 2.00, 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(6, 3, 7, 'Lift', 'Service', 15.00, 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(7, 3, 5, 'Parking', 'Common', 10.00, 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(8, 1, 1, 'Electrical Room', 'Service', 18.00, 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(9, 3, 6, 'Garden', 'Outdoor', 1.00, 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(10, 1, 1, 'Staircase', 'Common', 10.00, 'Active', '2026-08-15 13:50:19', '2026-08-17 13:36:22'),
(11, 2, 3, 'Common Corridor', 'Common', 5.00, 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(12, 1, NULL, 'AC Indoor Unit Area', 'Private', 6.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(13, 2, NULL, 'AC Indoor Unit Area', 'Private', 6.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(14, 3, NULL, 'AC Indoor Unit Area', 'Private', 6.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(15, 1, NULL, 'AC Outdoor Unit Area', 'Service', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(16, 2, NULL, 'AC Outdoor Unit Area', 'Service', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(17, 3, NULL, 'AC Outdoor Unit Area', 'Service', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(18, 1, NULL, 'Balcony', 'Private', 6.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(19, 2, NULL, 'Balcony', 'Private', 6.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(20, 3, NULL, 'Balcony', 'Private', 6.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(21, 1, NULL, 'Basement Parking Area', 'Common', 12.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(22, 2, NULL, 'Basement Parking Area', 'Common', 12.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(23, 3, NULL, 'Basement Parking Area', 'Common', 12.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(24, 1, NULL, 'Bathroom', 'Private', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(25, 2, NULL, 'Bathroom', 'Private', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(26, 3, NULL, 'Bathroom', 'Private', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(27, 1, NULL, 'Bedroom', 'Private', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(28, 2, NULL, 'Bedroom', 'Private', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(29, 3, NULL, 'Bedroom', 'Private', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(30, 1, NULL, 'Bicycle Parking Area', 'Common', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(31, 2, NULL, 'Bicycle Parking Area', 'Common', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(32, 3, NULL, 'Bicycle Parking Area', 'Common', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(33, 1, NULL, 'CCTV / Network Room', 'Service', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(34, 2, NULL, 'CCTV / Network Room', 'Service', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(35, 3, NULL, 'CCTV / Network Room', 'Service', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(36, 1, NULL, 'Ceiling', 'Private', 7.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(37, 2, NULL, 'Ceiling', 'Private', 7.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(38, 3, NULL, 'Ceiling', 'Private', 7.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(39, 1, NULL, 'Community Hall', 'Common', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(40, 2, NULL, 'Community Hall', 'Common', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(41, 3, NULL, 'Community Hall', 'Common', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(42, 1, NULL, 'Entrance / Main Door', 'Private', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(43, 2, NULL, 'Entrance / Main Door', 'Private', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(44, 3, NULL, 'Entrance / Main Door', 'Private', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(45, 1, NULL, 'Fire Assembly Point', 'Outdoor', 6.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(46, 2, NULL, 'Fire Assembly Point', 'Outdoor', 6.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(47, 3, NULL, 'Fire Assembly Point', 'Outdoor', 6.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(48, 1, NULL, 'Fire Control Room', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(49, 2, NULL, 'Fire Control Room', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(50, 3, NULL, 'Fire Control Room', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(51, 1, NULL, 'Floor Surface', 'Private', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(52, 2, NULL, 'Floor Surface', 'Private', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(53, 3, NULL, 'Floor Surface', 'Private', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(54, 1, NULL, 'Garbage Collection Room', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(55, 2, NULL, 'Garbage Collection Room', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(56, 3, NULL, 'Garbage Collection Room', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(57, 1, NULL, 'Garden / Landscape Area', 'Outdoor', 3.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(58, 2, NULL, 'Garden / Landscape Area', 'Outdoor', 3.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(59, 3, NULL, 'Garden / Landscape Area', 'Outdoor', 3.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(60, 1, NULL, 'Generator Room', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(61, 2, NULL, 'Generator Room', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(62, 3, NULL, 'Generator Room', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(63, 1, NULL, 'Gym / Fitness Area', 'Common', 6.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(64, 2, NULL, 'Gym / Fitness Area', 'Common', 6.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(65, 3, NULL, 'Gym / Fitness Area', 'Common', 6.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(66, 1, NULL, 'Intercom / Access Control Area', 'Service', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(67, 2, NULL, 'Intercom / Access Control Area', 'Service', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(68, 3, NULL, 'Intercom / Access Control Area', 'Service', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(69, 1, NULL, 'Internal Electrical Panel', 'Private', 18.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(70, 2, NULL, 'Internal Electrical Panel', 'Private', 18.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(71, 3, NULL, 'Internal Electrical Panel', 'Private', 18.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(72, 1, NULL, 'Kitchen', 'Private', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(73, 2, NULL, 'Kitchen', 'Private', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(74, 3, NULL, 'Kitchen', 'Private', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(75, 1, NULL, 'Laundry / Utility Area', 'Private', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(76, 2, NULL, 'Laundry / Utility Area', 'Private', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(77, 3, NULL, 'Laundry / Utility Area', 'Private', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(78, 1, NULL, 'Lift Machine Room', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(79, 2, NULL, 'Lift Machine Room', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(80, 3, NULL, 'Lift Machine Room', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(81, 1, NULL, 'Living Room', 'Private', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(82, 2, NULL, 'Living Room', 'Private', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(83, 3, NULL, 'Living Room', 'Private', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(84, 1, NULL, 'Loading / Service Area', 'Service', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(85, 2, NULL, 'Loading / Service Area', 'Service', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(86, 3, NULL, 'Loading / Service Area', 'Service', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(87, 1, NULL, 'Mail / Parcel Area', 'Common', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(88, 2, NULL, 'Mail / Parcel Area', 'Common', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(89, 3, NULL, 'Mail / Parcel Area', 'Common', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(90, 1, NULL, 'Main Drainage Area', 'Service', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(91, 2, NULL, 'Main Drainage Area', 'Service', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(92, 3, NULL, 'Main Drainage Area', 'Service', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(93, 1, NULL, 'Main Electrical Room', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(94, 2, NULL, 'Main Electrical Room', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(95, 3, NULL, 'Main Electrical Room', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(96, 1, NULL, 'Main Entrance', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(97, 2, NULL, 'Main Entrance', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(98, 3, NULL, 'Main Entrance', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(99, 1, NULL, 'Main Gate / Vehicle Entrance', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(100, 2, NULL, 'Main Gate / Vehicle Entrance', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(101, 3, NULL, 'Main Gate / Vehicle Entrance', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(102, 1, NULL, 'Management Office', 'Service', 3.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(103, 2, NULL, 'Management Office', 'Service', 3.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(104, 3, NULL, 'Management Office', 'Service', 3.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(105, 1, NULL, 'Master Bedroom', 'Private', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(106, 2, NULL, 'Master Bedroom', 'Private', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(107, 3, NULL, 'Master Bedroom', 'Private', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(108, 1, NULL, 'Parking Area', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(109, 2, NULL, 'Parking Area', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(110, 3, NULL, 'Parking Area', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(111, 1, NULL, 'Perimeter / Boundary Area', 'Outdoor', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(112, 2, NULL, 'Perimeter / Boundary Area', 'Outdoor', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(113, 3, NULL, 'Perimeter / Boundary Area', 'Outdoor', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(114, 1, NULL, 'Playground', 'Outdoor', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(115, 2, NULL, 'Playground', 'Outdoor', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(116, 3, NULL, 'Playground', 'Outdoor', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(117, 1, NULL, 'Plumbing Fixture Area', 'Private', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(118, 2, NULL, 'Plumbing Fixture Area', 'Private', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(119, 3, NULL, 'Plumbing Fixture Area', 'Private', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(120, 1, NULL, 'Pump Room', 'Service', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(121, 2, NULL, 'Pump Room', 'Service', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(122, 3, NULL, 'Pump Room', 'Service', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(123, 1, NULL, 'Reception / Main Lobby', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(124, 2, NULL, 'Reception / Main Lobby', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(125, 3, NULL, 'Reception / Main Lobby', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(126, 1, NULL, 'Roof Drainage Area', 'Outdoor', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(127, 2, NULL, 'Roof Drainage Area', 'Outdoor', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(128, 3, NULL, 'Roof Drainage Area', 'Outdoor', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(129, 1, NULL, 'Rooftop / Roof Area', 'Outdoor', 18.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(130, 2, NULL, 'Rooftop / Roof Area', 'Outdoor', 18.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(131, 3, NULL, 'Rooftop / Roof Area', 'Outdoor', 18.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(132, 1, NULL, 'Security Room', 'Service', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(133, 2, NULL, 'Security Room', 'Service', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(134, 3, NULL, 'Security Room', 'Service', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(135, 1, NULL, 'Sewer / Manhole Area', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(136, 2, NULL, 'Sewer / Manhole Area', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(137, 3, NULL, 'Sewer / Manhole Area', 'Service', 28.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(138, 1, NULL, 'Solar Panel Area', 'Service', 18.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(139, 2, NULL, 'Solar Panel Area', 'Service', 18.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(140, 3, NULL, 'Solar Panel Area', 'Service', 18.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(141, 1, NULL, 'Storeroom', 'Private', 3.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(142, 2, NULL, 'Storeroom', 'Private', 3.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(143, 3, NULL, 'Storeroom', 'Private', 3.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(144, 1, NULL, 'Swimming Pool Area', 'Outdoor', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(145, 2, NULL, 'Swimming Pool Area', 'Outdoor', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(146, 3, NULL, 'Swimming Pool Area', 'Outdoor', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(147, 1, NULL, 'Visitor Waiting Area', 'Common', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(148, 2, NULL, 'Visitor Waiting Area', 'Common', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(149, 3, NULL, 'Visitor Waiting Area', 'Common', 2.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(150, 1, NULL, 'Wall', 'Private', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(151, 2, NULL, 'Wall', 'Private', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(152, 3, NULL, 'Wall', 'Private', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(153, 1, NULL, 'Waste Storage Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(154, 2, NULL, 'Waste Storage Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(155, 3, NULL, 'Waste Storage Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(156, 1, NULL, 'Water Meter Area', 'Service', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(157, 2, NULL, 'Water Meter Area', 'Service', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(158, 3, NULL, 'Water Meter Area', 'Service', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(159, 1, NULL, 'Water Tank Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(160, 2, NULL, 'Water Tank Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(161, 3, NULL, 'Water Tank Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(162, 1, NULL, 'Window Area', 'Private', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(163, 2, NULL, 'Window Area', 'Private', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(164, 3, NULL, 'Window Area', 'Private', 4.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(267, 1, 1, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(268, 1, 2, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(269, 1, 8, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(270, 1, 11, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(271, 1, 14, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(272, 1, 16, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(273, 1, 21, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(274, 1, 24, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(275, 1, 27, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(276, 1, 29, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(277, 1, 32, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(278, 1, 35, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(279, 1, 1, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(280, 1, 2, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(281, 1, 8, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(282, 1, 11, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(283, 1, 14, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(284, 1, 16, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(285, 1, 21, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(286, 1, 24, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(287, 1, 27, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(288, 1, 29, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(289, 1, 32, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(290, 1, 35, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(291, 1, 1, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(292, 1, 2, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(293, 1, 8, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(294, 1, 11, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(295, 1, 14, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(296, 1, 16, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(297, 1, 21, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(298, 1, 24, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(299, 1, 27, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(300, 1, 29, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(301, 1, 32, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(302, 1, 35, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(303, 1, 1, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(304, 1, 2, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(305, 1, 8, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(306, 1, 11, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(307, 1, 14, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(308, 1, 16, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(309, 1, 21, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(310, 1, 24, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(311, 1, 27, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(312, 1, 29, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(313, 1, 32, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(314, 1, 35, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(315, 1, 1, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(316, 1, 2, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(317, 1, 8, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(318, 1, 11, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(319, 1, 14, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(320, 1, 16, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(321, 1, 21, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(322, 1, 24, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(323, 1, 27, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(324, 1, 29, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(325, 1, 32, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(326, 1, 35, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(327, 1, 1, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(328, 1, 2, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(329, 1, 8, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(330, 1, 11, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(331, 1, 14, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(332, 1, 16, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(333, 1, 21, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(334, 1, 24, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(335, 1, 27, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(336, 1, 29, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(337, 1, 32, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(338, 1, 35, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(339, 1, 1, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(340, 1, 2, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(341, 1, 8, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(342, 1, 11, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(343, 1, 14, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(344, 1, 16, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(345, 1, 21, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(346, 1, 24, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(347, 1, 27, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(348, 1, 29, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(349, 1, 32, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(350, 1, 35, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(351, 1, 1, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(352, 1, 2, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(353, 1, 8, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(354, 1, 11, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(355, 1, 14, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(356, 1, 16, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(357, 1, 21, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(358, 1, 24, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(359, 1, 27, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(360, 1, 29, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(361, 1, 32, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(362, 1, 35, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(363, 1, 1, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(364, 1, 2, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(365, 1, 8, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(366, 1, 11, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(367, 1, 14, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(368, 1, 16, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(369, 1, 21, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(370, 1, 24, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(371, 1, 27, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(372, 1, 29, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(373, 1, 32, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(374, 1, 35, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(375, 1, 2, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(376, 1, 8, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(377, 1, 11, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(378, 1, 14, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(379, 1, 16, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(380, 1, 21, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(381, 1, 24, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(382, 1, 27, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(383, 1, 29, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(384, 1, 32, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(385, 1, 35, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(386, 1, 38, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(387, 1, 41, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(388, 1, 44, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(389, 1, 47, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(390, 2, 3, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(391, 2, 4, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(392, 2, 9, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(393, 2, 12, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(394, 2, 17, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(395, 2, 19, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(396, 2, 22, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(397, 2, 25, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(398, 1, 38, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(399, 1, 41, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(400, 1, 44, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(401, 1, 47, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(402, 2, 3, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(403, 2, 4, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(404, 2, 9, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(405, 2, 12, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(406, 2, 17, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(407, 2, 19, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(408, 2, 22, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(409, 2, 25, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(410, 1, 38, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(411, 1, 41, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(412, 1, 44, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(413, 1, 47, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(414, 2, 3, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(415, 2, 4, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(416, 2, 9, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(417, 2, 12, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(418, 2, 17, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(419, 2, 19, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(420, 2, 22, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(421, 2, 25, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(422, 1, 38, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(423, 1, 41, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(424, 1, 44, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(425, 1, 47, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(426, 2, 3, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(427, 2, 4, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(428, 2, 9, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(429, 2, 12, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(430, 2, 17, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(431, 2, 19, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(432, 2, 22, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(433, 2, 25, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(434, 1, 38, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(435, 1, 41, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(436, 1, 44, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(437, 1, 47, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(438, 2, 3, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(439, 2, 4, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(440, 2, 9, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(441, 2, 12, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(442, 2, 17, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(443, 2, 19, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(444, 2, 22, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(445, 2, 25, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(446, 1, 38, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(447, 1, 41, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(448, 1, 44, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(449, 1, 47, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(450, 2, 3, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(451, 2, 4, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(452, 2, 9, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(453, 2, 12, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(454, 2, 17, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(455, 2, 19, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(456, 2, 22, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(457, 2, 25, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(458, 1, 38, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(459, 1, 41, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(460, 1, 44, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(461, 1, 47, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(462, 2, 3, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(463, 2, 4, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(464, 2, 9, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(465, 2, 12, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(466, 2, 17, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(467, 2, 19, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(468, 2, 22, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(469, 2, 25, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(470, 1, 38, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(471, 1, 41, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(472, 1, 44, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(473, 1, 47, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(474, 2, 3, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(475, 2, 4, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(476, 2, 9, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(477, 2, 12, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(478, 2, 17, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(479, 2, 19, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(480, 2, 22, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(481, 2, 25, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(482, 1, 38, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(483, 1, 41, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(484, 1, 44, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(485, 1, 47, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(486, 2, 3, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(487, 2, 4, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(488, 2, 9, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(489, 2, 12, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(490, 2, 17, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(491, 2, 19, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(492, 2, 22, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(493, 2, 25, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(494, 1, 38, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(495, 1, 41, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(496, 1, 44, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(497, 1, 47, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(498, 2, 3, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(499, 2, 4, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(500, 2, 9, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(501, 2, 12, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(502, 2, 17, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(503, 2, 19, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(504, 2, 22, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(505, 2, 25, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(506, 2, 28, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(507, 2, 30, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(508, 2, 33, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(509, 2, 36, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(510, 2, 39, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(511, 2, 42, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(512, 2, 45, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(513, 2, 48, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(514, 3, 5, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(515, 3, 6, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(516, 3, 7, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(517, 3, 10, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(518, 2, 28, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(519, 2, 30, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(520, 2, 33, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(521, 2, 36, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(522, 2, 39, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(523, 2, 42, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(524, 2, 45, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(525, 2, 48, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(526, 3, 5, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(527, 3, 6, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(528, 3, 7, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(529, 3, 10, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(530, 2, 28, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(531, 2, 30, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(532, 2, 33, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(533, 2, 36, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(534, 2, 39, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(535, 2, 42, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(536, 2, 45, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(537, 2, 48, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(538, 3, 5, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(539, 3, 6, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(540, 3, 7, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(541, 3, 10, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(542, 2, 28, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(543, 2, 30, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(544, 2, 33, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(545, 2, 36, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(546, 2, 39, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(547, 2, 42, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(548, 2, 45, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(549, 2, 48, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(550, 3, 5, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(551, 3, 6, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(552, 3, 7, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(553, 3, 10, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(554, 2, 28, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(555, 2, 30, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(556, 2, 33, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(557, 2, 36, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(558, 2, 39, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(559, 2, 42, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(560, 2, 45, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(561, 2, 48, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(562, 3, 5, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(563, 3, 6, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(564, 3, 7, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(565, 3, 10, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(566, 2, 28, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(567, 2, 30, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(568, 2, 33, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(569, 2, 36, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(570, 2, 39, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(571, 2, 42, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(572, 2, 45, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(573, 2, 48, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(574, 3, 5, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(575, 3, 6, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(576, 3, 7, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(577, 3, 10, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(578, 2, 28, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22');
INSERT INTO `areas` (`area_id`, `building_id`, `floor_id`, `name`, `area_type`, `risk_weight`, `status`, `created_at`, `updated_at`) VALUES
(579, 2, 30, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(580, 2, 33, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(581, 2, 36, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(582, 2, 39, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(583, 2, 42, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(584, 2, 45, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(585, 2, 48, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(586, 3, 5, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(587, 3, 6, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(588, 3, 7, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(589, 3, 10, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(590, 2, 28, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(591, 2, 30, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(592, 2, 33, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(593, 2, 36, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(594, 2, 39, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(595, 2, 42, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(596, 2, 45, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(597, 2, 48, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(598, 3, 5, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(599, 3, 6, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(600, 3, 7, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(601, 3, 10, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(602, 2, 28, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(603, 2, 30, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(604, 2, 33, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(605, 2, 36, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(606, 2, 39, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(607, 2, 42, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(608, 2, 45, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(609, 2, 48, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(610, 3, 5, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(611, 3, 6, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(612, 3, 7, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(613, 3, 10, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(614, 2, 28, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(615, 2, 30, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(616, 2, 33, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(617, 2, 36, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(618, 2, 39, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(619, 2, 42, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(620, 2, 45, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(621, 2, 48, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(622, 3, 5, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(623, 3, 6, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(624, 3, 7, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(625, 3, 10, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(626, 3, 13, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(627, 3, 15, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(628, 3, 18, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(629, 3, 20, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(630, 3, 23, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(631, 3, 26, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(632, 3, 31, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(633, 3, 34, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(634, 3, 37, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(635, 3, 40, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(636, 3, 43, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(637, 3, 46, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(638, 3, 13, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(639, 3, 15, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(640, 3, 18, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(641, 3, 20, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(642, 3, 23, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(643, 3, 26, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(644, 3, 31, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(645, 3, 34, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(646, 3, 37, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(647, 3, 40, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(648, 3, 43, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(649, 3, 46, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(650, 3, 13, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(651, 3, 15, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(652, 3, 18, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(653, 3, 20, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(654, 3, 23, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(655, 3, 26, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(656, 3, 31, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(657, 3, 34, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(658, 3, 37, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(659, 3, 40, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(660, 3, 43, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(661, 3, 46, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(662, 3, 13, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(663, 3, 15, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(664, 3, 18, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(665, 3, 20, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(666, 3, 23, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(667, 3, 26, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(668, 3, 31, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(669, 3, 34, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(670, 3, 37, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(671, 3, 40, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(672, 3, 43, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(673, 3, 46, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(674, 3, 13, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(675, 3, 15, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(676, 3, 18, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(677, 3, 20, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(678, 3, 23, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(679, 3, 26, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(680, 3, 31, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(681, 3, 34, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(682, 3, 37, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(683, 3, 40, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(684, 3, 43, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(685, 3, 46, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(686, 3, 13, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(687, 3, 15, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(688, 3, 18, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(689, 3, 20, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(690, 3, 23, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(691, 3, 26, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(692, 3, 31, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(693, 3, 34, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(694, 3, 37, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(695, 3, 40, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(696, 3, 43, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(697, 3, 46, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(698, 3, 13, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(699, 3, 15, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(700, 3, 18, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(701, 3, 20, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(702, 3, 23, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(703, 3, 26, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(704, 3, 31, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(705, 3, 34, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(706, 3, 37, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(707, 3, 40, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(708, 3, 43, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(709, 3, 46, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(710, 3, 13, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(711, 3, 15, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(712, 3, 18, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(713, 3, 20, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(714, 3, 23, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(715, 3, 26, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(716, 3, 31, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(717, 3, 34, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(718, 3, 37, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(719, 3, 40, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(720, 3, 43, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(721, 3, 46, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(722, 3, 13, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(723, 3, 15, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(724, 3, 18, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(725, 3, 20, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(726, 3, 23, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(727, 3, 26, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(728, 3, 31, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(729, 3, 34, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(730, 3, 37, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(731, 3, 40, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(732, 3, 43, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(733, 3, 46, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(734, 3, 13, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(735, 3, 15, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(736, 3, 18, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(737, 3, 20, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(738, 3, 23, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(739, 3, 26, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(740, 3, 31, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(741, 3, 34, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(742, 3, 37, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(743, 3, 40, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(744, 3, 43, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(745, 3, 46, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(746, 3, 49, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(747, 3, 49, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(748, 3, 49, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(749, 3, 49, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(750, 3, 49, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(751, 3, 49, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(752, 3, 49, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(753, 3, 49, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(754, 3, 49, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(755, 3, 49, 'Staircase', 'Common', 10.00, 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(756, 4, NULL, 'AC Indoor Unit Area', 'Private', 6.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(757, 7, NULL, 'AC Indoor Unit Area', 'Private', 6.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(758, 4, NULL, 'AC Outdoor Unit Area', 'Service', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(759, 7, NULL, 'AC Outdoor Unit Area', 'Service', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(760, 4, NULL, 'Balcony', 'Private', 6.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(761, 7, NULL, 'Balcony', 'Private', 6.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(762, 4, NULL, 'Basement Parking Area', 'Common', 12.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(763, 7, NULL, 'Basement Parking Area', 'Common', 12.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(764, 4, NULL, 'Bathroom', 'Private', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(765, 7, NULL, 'Bathroom', 'Private', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(766, 4, NULL, 'Bedroom', 'Private', 2.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(767, 7, NULL, 'Bedroom', 'Private', 2.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(768, 4, NULL, 'Bicycle Parking Area', 'Common', 4.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(769, 7, NULL, 'Bicycle Parking Area', 'Common', 4.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(770, 4, NULL, 'CCTV / Network Room', 'Service', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(771, 7, NULL, 'CCTV / Network Room', 'Service', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(772, 4, NULL, 'Ceiling', 'Private', 7.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(773, 7, NULL, 'Ceiling', 'Private', 7.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(774, 4, NULL, 'Community Hall', 'Common', 4.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(775, 7, NULL, 'Community Hall', 'Common', 4.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(776, 4, NULL, 'Entrance / Main Door', 'Private', 4.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(777, 7, NULL, 'Entrance / Main Door', 'Private', 4.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(778, 4, NULL, 'Fire Assembly Point', 'Outdoor', 6.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(779, 7, NULL, 'Fire Assembly Point', 'Outdoor', 6.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(780, 4, NULL, 'Fire Control Room', 'Service', 28.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(781, 7, NULL, 'Fire Control Room', 'Service', 28.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(782, 4, NULL, 'Floor Surface', 'Private', 4.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(783, 7, NULL, 'Floor Surface', 'Private', 4.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(784, 4, NULL, 'Garbage Collection Room', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(785, 7, NULL, 'Garbage Collection Room', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(786, 4, NULL, 'Garden / Landscape Area', 'Outdoor', 3.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(787, 7, NULL, 'Garden / Landscape Area', 'Outdoor', 3.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(788, 4, NULL, 'Generator Room', 'Service', 28.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(789, 7, NULL, 'Generator Room', 'Service', 28.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(790, 4, NULL, 'Gym / Fitness Area', 'Common', 6.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(791, 7, NULL, 'Gym / Fitness Area', 'Common', 6.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(792, 4, NULL, 'Intercom / Access Control Area', 'Service', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(793, 7, NULL, 'Intercom / Access Control Area', 'Service', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(794, 4, NULL, 'Internal Electrical Panel', 'Private', 18.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(795, 7, NULL, 'Internal Electrical Panel', 'Private', 18.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(796, 4, NULL, 'Kitchen', 'Private', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(797, 7, NULL, 'Kitchen', 'Private', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(798, 4, NULL, 'Laundry / Utility Area', 'Private', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(799, 7, NULL, 'Laundry / Utility Area', 'Private', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(800, 4, NULL, 'Lift Machine Room', 'Service', 28.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(801, 7, NULL, 'Lift Machine Room', 'Service', 28.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(802, 4, NULL, 'Living Room', 'Private', 2.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(803, 7, NULL, 'Living Room', 'Private', 2.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(804, 4, NULL, 'Loading / Service Area', 'Service', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(805, 7, NULL, 'Loading / Service Area', 'Service', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(806, 4, NULL, 'Mail / Parcel Area', 'Common', 2.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(807, 7, NULL, 'Mail / Parcel Area', 'Common', 2.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(808, 4, NULL, 'Main Drainage Area', 'Service', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(809, 7, NULL, 'Main Drainage Area', 'Service', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(810, 4, NULL, 'Main Electrical Room', 'Service', 28.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(811, 7, NULL, 'Main Electrical Room', 'Service', 28.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(812, 4, NULL, 'Main Entrance', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(813, 7, NULL, 'Main Entrance', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(814, 4, NULL, 'Main Gate / Vehicle Entrance', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(815, 7, NULL, 'Main Gate / Vehicle Entrance', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(816, 4, NULL, 'Management Office', 'Service', 3.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(817, 7, NULL, 'Management Office', 'Service', 3.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(818, 4, NULL, 'Master Bedroom', 'Private', 2.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(819, 7, NULL, 'Master Bedroom', 'Private', 2.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(820, 4, NULL, 'Parking Area', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(821, 7, NULL, 'Parking Area', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(822, 4, NULL, 'Perimeter / Boundary Area', 'Outdoor', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(823, 7, NULL, 'Perimeter / Boundary Area', 'Outdoor', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(824, 4, NULL, 'Plumbing Fixture Area', 'Private', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(825, 7, NULL, 'Plumbing Fixture Area', 'Private', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(826, 4, NULL, 'Pump Room', 'Service', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(827, 7, NULL, 'Pump Room', 'Service', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(828, 4, NULL, 'Reception / Main Lobby', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(829, 7, NULL, 'Reception / Main Lobby', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(830, 4, NULL, 'Roof Drainage Area', 'Outdoor', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(831, 7, NULL, 'Roof Drainage Area', 'Outdoor', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(832, 4, NULL, 'Rooftop / Roof Area', 'Outdoor', 18.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(833, 7, NULL, 'Rooftop / Roof Area', 'Outdoor', 18.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(834, 4, NULL, 'Security Room', 'Service', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(835, 7, NULL, 'Security Room', 'Service', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(836, 4, NULL, 'Sewer / Manhole Area', 'Service', 28.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(837, 7, NULL, 'Sewer / Manhole Area', 'Service', 28.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(838, 4, NULL, 'Solar Panel Area', 'Service', 18.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(839, 7, NULL, 'Solar Panel Area', 'Service', 18.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(840, 4, NULL, 'Storeroom', 'Private', 3.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(841, 7, NULL, 'Storeroom', 'Private', 3.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(842, 4, NULL, 'Swimming Pool Area', 'Outdoor', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(843, 7, NULL, 'Swimming Pool Area', 'Outdoor', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(844, 4, NULL, 'Visitor Waiting Area', 'Common', 2.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(845, 7, NULL, 'Visitor Waiting Area', 'Common', 2.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(846, 4, NULL, 'Wall', 'Private', 4.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(847, 7, NULL, 'Wall', 'Private', 4.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(848, 4, NULL, 'Waste Storage Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(849, 7, NULL, 'Waste Storage Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(850, 4, NULL, 'Water Meter Area', 'Service', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(851, 7, NULL, 'Water Meter Area', 'Service', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(852, 4, NULL, 'Water Tank Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(853, 7, NULL, 'Water Tank Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(854, 4, NULL, 'Window Area', 'Private', 4.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(855, 7, NULL, 'Window Area', 'Private', 4.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(883, 1, 50, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(884, 1, 50, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(885, 1, 50, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(886, 1, 50, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(887, 1, 50, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(888, 1, 50, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(889, 1, 50, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(890, 1, 50, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(891, 1, 50, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(892, 1, 50, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(893, 3, 51, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(894, 4, 52, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(895, 4, 53, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(896, 4, 54, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(897, 4, 55, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(898, 4, 56, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(899, 4, 57, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(900, 4, 58, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(901, 4, 59, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(902, 4, 60, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(903, 4, 61, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(904, 7, 62, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(905, 7, 63, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(906, 7, 64, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(907, 7, 65, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(908, 7, 66, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(909, 7, 67, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(910, 7, 68, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(911, 7, 69, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(912, 7, 70, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(913, 7, 71, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(914, 7, 72, 'Common Washroom', 'Common', 8.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(915, 3, 51, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(916, 4, 52, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(917, 4, 53, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(918, 4, 54, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(919, 4, 55, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(920, 4, 56, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(921, 4, 57, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(922, 4, 58, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(923, 4, 59, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(924, 4, 60, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(925, 4, 61, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(926, 7, 62, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(927, 7, 63, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(928, 7, 64, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(929, 7, 65, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(930, 7, 66, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(931, 7, 67, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(932, 7, 68, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(933, 7, 69, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(934, 7, 70, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(935, 7, 71, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(936, 7, 72, 'Electrical Riser', 'Service', 24.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(937, 3, 51, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(938, 4, 52, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(939, 4, 53, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(940, 4, 54, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(941, 4, 55, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(942, 4, 56, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(943, 4, 57, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(944, 4, 58, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(945, 4, 59, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(946, 4, 60, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(947, 4, 61, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(948, 7, 62, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(949, 7, 63, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(950, 7, 64, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(951, 7, 65, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(952, 7, 66, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(953, 7, 67, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(954, 7, 68, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(955, 7, 69, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(956, 7, 70, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(957, 7, 71, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(958, 7, 72, 'Emergency Lighting Area', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(959, 3, 51, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(960, 4, 52, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(961, 4, 53, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(962, 4, 54, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(963, 4, 55, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(964, 4, 56, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(965, 4, 57, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(966, 4, 58, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(967, 4, 59, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(968, 4, 60, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(969, 4, 61, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(970, 7, 62, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(971, 7, 63, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(972, 7, 64, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(973, 7, 65, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(974, 7, 66, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(975, 7, 67, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(976, 7, 68, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(977, 7, 69, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(978, 7, 70, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(979, 7, 71, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(980, 7, 72, 'Fire Exit', 'Common', 20.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(981, 3, 51, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(982, 4, 52, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(983, 4, 53, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(984, 4, 54, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(985, 4, 55, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(986, 4, 56, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(987, 4, 57, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(988, 4, 58, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(989, 4, 59, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(990, 4, 60, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(991, 4, 61, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(992, 7, 62, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(993, 7, 63, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(994, 7, 64, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(995, 7, 65, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(996, 7, 66, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(997, 7, 67, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(998, 7, 68, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(999, 7, 69, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1000, 7, 70, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1001, 7, 71, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1002, 7, 72, 'Fire Hose / Reel Area', 'Service', 22.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1003, 3, 51, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1004, 4, 52, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1005, 4, 53, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1006, 4, 54, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1007, 4, 55, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1008, 4, 56, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1009, 4, 57, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1010, 4, 58, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1011, 4, 59, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1012, 4, 60, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1013, 4, 61, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1014, 7, 62, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1015, 7, 63, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1016, 7, 64, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1017, 7, 65, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1018, 7, 66, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1019, 7, 67, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1020, 7, 68, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1021, 7, 69, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1022, 7, 70, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1023, 7, 71, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1024, 7, 72, 'Lift Lobby', 'Common', 14.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1025, 3, 51, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1026, 4, 52, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1027, 4, 53, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1028, 4, 54, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1029, 4, 55, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1030, 4, 56, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1031, 4, 57, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1032, 4, 58, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1033, 4, 59, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1034, 4, 60, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1035, 4, 61, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1036, 7, 62, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1037, 7, 63, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1038, 7, 64, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1039, 7, 65, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1040, 7, 66, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1041, 7, 67, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1042, 7, 68, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1043, 7, 69, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1044, 7, 70, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1045, 7, 71, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1046, 7, 72, 'Main Corridor', 'Common', 5.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1047, 3, 51, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1048, 4, 52, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1049, 4, 53, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1050, 4, 54, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1051, 4, 55, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1052, 4, 56, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1053, 4, 57, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1054, 4, 58, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1055, 4, 59, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1056, 4, 60, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1057, 4, 61, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1058, 7, 62, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1059, 7, 63, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1060, 7, 64, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1061, 7, 65, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1062, 7, 66, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1063, 7, 67, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1064, 7, 68, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1065, 7, 69, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1066, 7, 70, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1067, 7, 71, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1068, 7, 72, 'Plumbing Riser', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1069, 3, 51, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1070, 4, 52, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1071, 4, 53, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1072, 4, 54, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1073, 4, 55, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1074, 4, 56, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1075, 4, 57, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1076, 4, 58, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1077, 4, 59, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1078, 4, 60, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1079, 4, 61, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1080, 7, 62, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1081, 7, 63, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26');
INSERT INTO `areas` (`area_id`, `building_id`, `floor_id`, `name`, `area_type`, `risk_weight`, `status`, `created_at`, `updated_at`) VALUES
(1082, 7, 64, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1083, 7, 65, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1084, 7, 66, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1085, 7, 67, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1086, 7, 68, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1087, 7, 69, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1088, 7, 70, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1089, 7, 71, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1090, 7, 72, 'Service Duct', 'Service', 16.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1091, 3, 51, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1092, 4, 52, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1093, 4, 53, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1094, 4, 54, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1095, 4, 55, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1096, 4, 56, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1097, 4, 57, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1098, 4, 58, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1099, 4, 59, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1100, 4, 60, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1101, 4, 61, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1102, 7, 62, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1103, 7, 63, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1104, 7, 64, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1105, 7, 65, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1106, 7, 66, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1107, 7, 67, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1108, 7, 68, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1109, 7, 69, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1110, 7, 70, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1111, 7, 71, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26'),
(1112, 7, 72, 'Staircase', 'Common', 10.00, 'Active', '2026-08-29 11:07:26', '2026-08-29 11:07:26');

-- --------------------------------------------------------

--
-- Table structure for table `audit_logs`
--

CREATE TABLE `audit_logs` (
  `audit_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED DEFAULT NULL,
  `action_type` varchar(100) NOT NULL,
  `entity_type` varchar(80) NOT NULL,
  `entity_id` varchar(80) DEFAULT NULL,
  `old_value` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`old_value`)),
  `new_value` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`new_value`)),
  `reason` varchar(1000) DEFAULT NULL,
  `ip_address` varchar(45) DEFAULT NULL,
  `user_agent` varchar(500) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `audit_logs`
--

INSERT INTO `audit_logs` (`audit_id`, `user_id`, `action_type`, `entity_type`, `entity_id`, `old_value`, `new_value`, `reason`, `ip_address`, `user_agent`, `created_at`) VALUES
(397, 15, 'Existing System Admin Preserved', 'users', '15', NULL, '{\"email\": \"rakindufernando@gmail.com\", \"role\": \"System Admin\", \"status\": \"Active\"}', 'The main HelaFixIt AI system administrator account was preserved while the old user data was cleared.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 12:00:00'),
(398, 15, 'User Created', 'users', '272', NULL, '{\"full_name\": \"Akila Dissanayake\", \"email\": \"akila.dissanayake@gmail.com\", \"role\": \"Resident\", \"building\": \"Block B\", \"floor\": 3, \"unit\": \"B-303\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:31:00'),
(399, 15, 'User Created', 'users', '273', NULL, '{\"full_name\": \"Amanda Perera\", \"email\": \"amanda.perera@outlook.com\", \"role\": \"Resident\", \"building\": \"Block E\", \"floor\": 1, \"unit\": \"E-101\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:34:00'),
(400, 15, 'User Created', 'users', '274', NULL, '{\"full_name\": \"Anjali Herath\", \"email\": \"anjali.herath@hotmail.com\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 5, \"unit\": \"C-505\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:01:00'),
(401, 15, 'User Created', 'users', '275', NULL, '{\"full_name\": \"Chamod Wickramasinghe\", \"email\": \"chamod.wickramasinghe@yahoo.com\", \"role\": \"Resident\", \"building\": \"Block B\", \"floor\": 8, \"unit\": \"B-808\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:46:00'),
(402, 15, 'User Created', 'users', '276', NULL, '{\"full_name\": \"Dhanushka Gunawardena\", \"email\": \"dhanushka.gunawardena@icloud.com\", \"role\": \"Resident\", \"building\": \"Block D\", \"floor\": 3, \"unit\": \"D-303\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:19:00'),
(403, 15, 'User Created', 'users', '277', NULL, '{\"full_name\": \"Dinithi Jayawardena\", \"email\": \"dinithi.jayawardena@live.com\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 3, \"unit\": \"A-303\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:07:00'),
(404, 15, 'User Created', 'users', '278', NULL, '{\"full_name\": \"Dulanjali De Silva\", \"email\": \"dulanjali.desilva@proton.me\", \"role\": \"Resident\", \"building\": \"Block B\", \"floor\": 7, \"unit\": \"B-707\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:43:00'),
(405, 15, 'User Created', 'users', '279', NULL, '{\"full_name\": \"Gimhani Silva\", \"email\": \"gimhani.silva@msn.com\", \"role\": \"Resident\", \"building\": \"Block D\", \"floor\": 2, \"unit\": \"D-202\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:16:00'),
(406, 15, 'User Created', 'users', '280', NULL, '{\"full_name\": \"Hasini Fernando\", \"email\": \"hasini.fernando@gmail.com\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 4, \"unit\": \"A-404\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:10:00'),
(407, 15, 'User Created', 'users', '281', NULL, '{\"full_name\": \"Hiruni Samarasinghe\", \"email\": \"hiruni.samarasinghe@outlook.com\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 3, \"unit\": \"C-303\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:55:00'),
(408, 15, 'User Created', 'users', '282', NULL, '{\"full_name\": \"Imesha Karunaratne\", \"email\": \"imesha.karunaratne@hotmail.com\", \"role\": \"Resident\", \"building\": \"Block B\", \"floor\": 6, \"unit\": \"B-606\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:40:00'),
(409, 15, 'User Created', 'users', '283', NULL, '{\"full_name\": \"Ishadi Fernando\", \"email\": \"ishadi.fernando@yahoo.com\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 8, \"unit\": \"C-808\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:10:00'),
(410, 15, 'User Created', 'users', '284', NULL, '{\"full_name\": \"Janith Ekanayake\", \"email\": \"janith.ekanayake@icloud.com\", \"role\": \"Resident\", \"building\": \"Block D\", \"floor\": 5, \"unit\": \"D-505\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:25:00'),
(411, 15, 'User Created', 'users', '285', NULL, '{\"full_name\": \"Kavindu Silva\", \"email\": \"kavindu.silva@live.com\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 2, \"unit\": \"A-202\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:04:00'),
(412, 15, 'User Created', 'users', '286', NULL, '{\"full_name\": \"Kusal Mendis\", \"email\": \"kusal.mendis@proton.me\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 2, \"unit\": \"C-202\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:52:00'),
(413, 15, 'User Created', 'users', '287', NULL, '{\"full_name\": \"Lahiru Dilshan\", \"email\": \"lahiru.dilshan@msn.com\", \"role\": \"Resident\", \"building\": \"Block E\", \"floor\": 2, \"unit\": \"E-202\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:37:00'),
(414, 15, 'User Created', 'users', '288', NULL, '{\"full_name\": \"Malith Senanayake\", \"email\": \"malith.senanayake@gmail.com\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 7, \"unit\": \"A-707\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:19:00'),
(415, 15, 'User Created', 'users', '289', NULL, '{\"full_name\": \"Manori Senanayake\", \"email\": \"manori.senanayake@outlook.com\", \"role\": \"Resident\", \"building\": \"Block E\", \"floor\": 6, \"unit\": \"E-606\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:49:00'),
(416, 15, 'User Created', 'users', '290', NULL, '{\"full_name\": \"Nadeesha Priyadarshani\", \"email\": \"nadeesha.priyadarshani@hotmail.com\", \"role\": \"Resident\", \"building\": \"Block D\", \"floor\": 6, \"unit\": \"D-606\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:28:00'),
(417, 15, 'User Created', 'users', '291', NULL, '{\"full_name\": \"Nimesh Wijesinghe\", \"email\": \"nimesh.wijesinghe@yahoo.com\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 5, \"unit\": \"A-505\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:13:00'),
(418, 15, 'User Created', 'users', '292', NULL, '{\"full_name\": \"Oshadi Gunasekara\", \"email\": \"oshadi.gunasekara@icloud.com\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 6, \"unit\": \"A-606\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:16:00'),
(419, 15, 'User Created', 'users', '293', NULL, '{\"full_name\": \"Pabasara Wijekoon\", \"email\": \"pabasara.wijekoon@live.com\", \"role\": \"Resident\", \"building\": \"Block E\", \"floor\": 5, \"unit\": \"E-505\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:46:00'),
(420, 15, 'User Created', 'users', '294', NULL, '{\"full_name\": \"Pasindu Bandara\", \"email\": \"pasindu.bandara@proton.me\", \"role\": \"Resident\", \"building\": \"Block B\", \"floor\": 5, \"unit\": \"B-505\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:37:00'),
(421, 15, 'User Created', 'users', '295', NULL, '{\"full_name\": \"Piumi Rathnayake\", \"email\": \"piumi.rathnayake@msn.com\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 8, \"unit\": \"A-808\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:22:00'),
(422, 15, 'User Created', 'users', '296', NULL, '{\"full_name\": \"Ravindu Lakshan\", \"email\": \"ravindu.lakshan@gmail.com\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 4, \"unit\": \"C-404\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:58:00'),
(423, 15, 'User Created', 'users', '297', NULL, '{\"full_name\": \"Nethmi Perera\", \"email\": \"nethmi.perera@outlook.com\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 1, \"unit\": \"A-101\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:01:00'),
(424, 15, 'User Created', 'users', '298', NULL, '{\"full_name\": \"Rukshan Fernando\", \"email\": \"rukshan.fernando@hotmail.com\", \"role\": \"Resident\", \"building\": \"Block E\", \"floor\": 4, \"unit\": \"E-404\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:43:00'),
(425, 15, 'User Created', 'users', '299', NULL, '{\"full_name\": \"Sachini Weerasinghe\", \"email\": \"sachini.weerasinghe@yahoo.com\", \"role\": \"Resident\", \"building\": \"Block B\", \"floor\": 4, \"unit\": \"B-404\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:34:00'),
(426, 15, 'User Created', 'users', '300', NULL, '{\"full_name\": \"Sandun Jayasekara\", \"email\": \"sandun.jayasekara@icloud.com\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 7, \"unit\": \"C-707\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:07:00'),
(427, 15, 'User Created', 'users', '301', NULL, '{\"full_name\": \"Sewwandi Kumari\", \"email\": \"sewwandi.kumari@live.com\", \"role\": \"Resident\", \"building\": \"Block D\", \"floor\": 4, \"unit\": \"D-404\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:22:00'),
(428, 15, 'User Created', 'users', '302', NULL, '{\"full_name\": \"Shashika Madurangi\", \"email\": \"shashika.madurangi@proton.me\", \"role\": \"Resident\", \"building\": \"Block E\", \"floor\": 3, \"unit\": \"E-303\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:40:00'),
(429, 15, 'User Created', 'users', '303', NULL, '{\"full_name\": \"Shehan Peiris\", \"email\": \"shehan.peiris@msn.com\", \"role\": \"Resident\", \"building\": \"Block B\", \"floor\": 1, \"unit\": \"B-101\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:25:00'),
(430, 15, 'User Created', 'users', '304', NULL, '{\"full_name\": \"Supun Niroshan\", \"email\": \"supun.niroshan@gmail.com\", \"role\": \"Resident\", \"building\": \"Block D\", \"floor\": 1, \"unit\": \"D-101\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:13:00'),
(431, 15, 'User Created', 'users', '305', NULL, '{\"full_name\": \"Tharushi Perera\", \"email\": \"tharushi.perera@outlook.com\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 6, \"unit\": \"C-606\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:04:00'),
(432, 15, 'User Created', 'users', '306', NULL, '{\"full_name\": \"Thilini Abeysekara\", \"email\": \"thilini.abeysekara@hotmail.com\", \"role\": \"Resident\", \"building\": \"Block B\", \"floor\": 2, \"unit\": \"B-202\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:28:00'),
(433, 15, 'User Created', 'users', '307', NULL, '{\"full_name\": \"Thiwanka Samarakoon\", \"email\": \"thiwanka.samarakoon@yahoo.com\", \"role\": \"Resident\", \"building\": \"Block E\", \"floor\": 7, \"unit\": \"E-707\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:52:00'),
(434, 15, 'User Created', 'users', '308', NULL, '{\"full_name\": \"Upeksha Madushani\", \"email\": \"upeksha.madushani@icloud.com\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 1, \"unit\": \"C-101\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 13:49:00'),
(435, 15, 'User Created', 'users', '309', NULL, '{\"full_name\": \"Vihanga Rajapaksha\", \"email\": \"vihanga.rajapaksha@live.com\", \"role\": \"Resident\", \"building\": \"Block D\", \"floor\": 7, \"unit\": \"D-707\"}', 'Resident account created during the HelaFixIt AI initial user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 14:31:00'),
(461, 15, 'User Created', 'users', '335', NULL, '{\"full_name\": \"Dilani Fernando\", \"email\": \"admin@helafixit.lk\", \"role\": \"Apartment Admin\", \"building\": \"Block A\", \"job_title\": \"Apartment Administrator\"}', 'Apartment administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:01:00'),
(462, 15, 'User Created', 'users', '336', NULL, '{\"full_name\": \"Chathurika Senanayake\", \"email\": \"chathurika.senanayake@helafixit.lk\", \"role\": \"Apartment Admin\", \"building\": \"Block C\", \"job_title\": \"Apartment Administrator\"}', 'Apartment administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:49:00'),
(463, 15, 'User Created', 'users', '337', NULL, '{\"full_name\": \"Dinusha Karunaratne\", \"email\": \"dinusha.karunaratne@helafixit.lk\", \"role\": \"Apartment Admin\", \"building\": \"Block D\", \"job_title\": \"Apartment Administrator\"}', 'Apartment administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 10:13:00'),
(464, 15, 'User Created', 'users', '338', NULL, '{\"full_name\": \"Gayani Rathnayake\", \"email\": \"gayani.rathnayake@helafixit.lk\", \"role\": \"Apartment Admin\", \"building\": \"Block E\", \"job_title\": \"Apartment Administrator\"}', 'Apartment administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 10:37:00'),
(465, 15, 'User Created', 'users', '339', NULL, '{\"full_name\": \"Harini Wijesinghe\", \"email\": \"harini.wijesinghe@helafixit.lk\", \"role\": \"Apartment Admin\", \"building\": \"Block B\", \"job_title\": \"Apartment Administrator\"}', 'Apartment administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:25:00'),
(466, 15, 'User Created', 'users', '340', NULL, '{\"full_name\": \"Iresha Jayasinghe\", \"email\": \"iresha.jayasinghe@helafixit.lk\", \"role\": \"Apartment Admin\", \"building\": \"Block C\", \"job_title\": \"Assistant Apartment Administrator\"}', 'Apartment administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 10:01:00'),
(467, 15, 'User Created', 'users', '341', NULL, '{\"full_name\": \"Nadeesha Perera\", \"email\": \"nadeesha.perera@helafixit.lk\", \"role\": \"Apartment Admin\", \"building\": \"Block A\", \"job_title\": \"Assistant Apartment Administrator\"}', 'Apartment administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:13:00'),
(468, 15, 'User Created', 'users', '342', NULL, '{\"full_name\": \"Sachini De Silva\", \"email\": \"sachini.de.silva@helafixit.lk\", \"role\": \"Apartment Admin\", \"building\": \"Block E\", \"job_title\": \"Assistant Apartment Administrator\"}', 'Apartment administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 10:49:00'),
(469, 15, 'User Created', 'users', '343', NULL, '{\"full_name\": \"Shalini Abeysekera\", \"email\": \"shalini.abeysekera@helafixit.lk\", \"role\": \"Apartment Admin\", \"building\": \"Block D\", \"job_title\": \"Assistant Apartment Administrator\"}', 'Apartment administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 10:25:00'),
(470, 15, 'User Created', 'users', '344', NULL, '{\"full_name\": \"Tharushi Gunawardena\", \"email\": \"tharushi.gunawardena@helafixit.lk\", \"role\": \"Apartment Admin\", \"building\": \"Block B\", \"job_title\": \"Assistant Apartment Administrator\"}', 'Apartment administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:37:00'),
(476, 15, 'User Created', 'users', '350', NULL, '{\"full_name\": \"Amila Perera\", \"email\": \"amila.perera.elec@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Electrical\", \"employee_code\": \"HFT-C-ELEC-01\"}', 'Technician account created for Electrical support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 08:31:00'),
(477, 15, 'User Created', 'users', '351', NULL, '{\"full_name\": \"Asanka Weerasinghe\", \"email\": \"asanka.weerasinghe.other@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Other\", \"employee_code\": \"HFT-A-OTHER-09\"}', 'Technician account created for Other support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 09:51:00'),
(478, 15, 'User Created', 'users', '352', NULL, '{\"full_name\": \"Ashan Senanayake\", \"email\": \"ashan.senanayake.pest@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Pest Control\", \"employee_code\": \"HFT-D-PEST-07\"}', 'Technician account created for Pest Control support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 14:01:00'),
(479, 15, 'User Created', 'users', '353', NULL, '{\"full_name\": \"Bimal Rathnayake\", \"email\": \"bimal.rathnayake.carp@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Carpentry\", \"employee_code\": \"HFT-D-CARP-08\"}', 'Technician account created for Carpentry support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 14:11:00'),
(480, 15, 'User Created', 'users', '354', NULL, '{\"full_name\": \"Buddhika Silva\", \"email\": \"buddhika.silva.plumb@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Plumbing\", \"employee_code\": \"HFT-C-PLUMB-02\"}', 'Technician account created for Plumbing support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 08:41:00'),
(481, 15, 'User Created', 'users', '355', NULL, '{\"full_name\": \"Chamara Perera\", \"email\": \"chamara.perera.plumb@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Plumbing\", \"employee_code\": \"HFT-A-PLUMB-02\"}', 'Technician account created for Plumbing support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 08:41:00'),
(482, 15, 'User Created', 'users', '356', NULL, '{\"full_name\": \"Chamil Fernando\", \"email\": \"chamil.fernando.lift@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Lift\", \"employee_code\": \"HFT-C-LIFT-03\"}', 'Technician account created for Lift support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 08:51:00'),
(483, 15, 'User Created', 'users', '357', NULL, '{\"full_name\": \"Charith Peiris\", \"email\": \"charith.peiris.other@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Other\", \"employee_code\": \"HFT-D-OTHER-09\"}', 'Technician account created for Other support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 14:21:00'),
(484, 15, 'User Created', 'users', '358', NULL, '{\"full_name\": \"Chathura Bandara\", \"email\": \"chathura.bandara.ac@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Air Conditioning\", \"employee_code\": \"HFT-B-AC-04\"}', 'Technician account created for Air Conditioning support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 13:31:00'),
(485, 15, 'User Created', 'users', '359', NULL, '{\"full_name\": \"Damith Dissanayake\", \"email\": \"damith.dissanayake.gas@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Gas\", \"employee_code\": \"HFT-B-GAS-11\"}', 'Technician account created for Gas support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 14:41:00'),
(486, 15, 'User Created', 'users', '360', NULL, '{\"full_name\": \"Darshana Herath\", \"email\": \"darshana.herath.fire@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Fire and Safety\", \"employee_code\": \"HFT-D-FIRE-10\"}', 'Technician account created for Fire and Safety support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 14:31:00'),
(487, 15, 'User Created', 'users', '361', NULL, '{\"full_name\": \"Dinesh Fernando\", \"email\": \"dinesh.fernando.ac@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Air Conditioning\", \"employee_code\": \"HFT-A-AC-04\"}', 'Technician account created for Air Conditioning support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 09:01:00'),
(488, 15, 'User Created', 'users', '362', NULL, '{\"full_name\": \"Eranga Wijekoon\", \"email\": \"eranga.wijekoon.struct@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Structural\", \"employee_code\": \"HFT-B-STRUCT-12\"}', 'Technician account created for Structural support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 14:51:00'),
(489, 15, 'User Created', 'users', '363', NULL, '{\"full_name\": \"Eshan Dissanayake\", \"email\": \"eshan.dissanayake.gas@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Gas\", \"employee_code\": \"HFT-D-GAS-11\"}', 'Technician account created for Gas support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 14:41:00'),
(490, 15, 'User Created', 'users', '364', NULL, '{\"full_name\": \"Fairooz Ahamed\", \"email\": \"fairooz.ahamed.struct@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Structural\", \"employee_code\": \"HFT-D-STRUCT-12\"}', 'Technician account created for Structural support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 14:51:00'),
(491, 15, 'User Created', 'users', '365', NULL, '{\"full_name\": \"Gayan Perera\", \"email\": \"gayan.perera.elec@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Electrical\", \"employee_code\": \"HFT-B-ELEC-01\"}', 'Technician account created for Electrical support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 13:01:00'),
(492, 15, 'User Created', 'users', '366', NULL, '{\"full_name\": \"Gihan Samarasinghe\", \"email\": \"gihan.samarasinghe.sec@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Security and Access\", \"employee_code\": \"HFT-D-SEC-13\"}', 'Technician account created for Security and Access support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 15:01:00'),
(493, 15, 'User Created', 'users', '367', NULL, '{\"full_name\": \"Harsha Bandara\", \"email\": \"harsha.bandara.ac@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Air Conditioning\", \"employee_code\": \"HFT-C-AC-04\"}', 'Technician account created for Air Conditioning support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 09:01:00'),
(494, 15, 'User Created', 'users', '368', NULL, '{\"full_name\": \"Heshan Perera\", \"email\": \"heshan.perera.elec@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Electrical\", \"employee_code\": \"HFT-E-ELEC-01\"}', 'Technician account created for Electrical support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 08:31:00'),
(495, 15, 'User Created', 'users', '369', NULL, '{\"full_name\": \"Indika Jayawardena\", \"email\": \"indika.jayawardena.drain@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Drainage\", \"employee_code\": \"HFT-C-DRAIN-05\"}', 'Technician account created for Drainage support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 09:11:00'),
(496, 15, 'User Created', 'users', '370', NULL, '{\"full_name\": \"Ishan Silva\", \"email\": \"ishan.silva.plumb@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Plumbing\", \"employee_code\": \"HFT-E-PLUMB-02\"}', 'Technician account created for Plumbing support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 08:41:00'),
(497, 15, 'User Created', 'users', '371', NULL, '{\"full_name\": \"Isuru Madushan\", \"email\": \"isuru.madushan.drain@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Drainage\", \"employee_code\": \"HFT-A-DRAIN-05\"}', 'Technician account created for Drainage support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 09:11:00'),
(498, 15, 'User Created', 'users', '372', NULL, '{\"full_name\": \"Janaka Rathnayake\", \"email\": \"janaka.rathnayake.carp@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Carpentry\", \"employee_code\": \"HFT-B-CARP-08\"}', 'Technician account created for Carpentry support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 14:11:00'),
(499, 15, 'User Created', 'users', '373', NULL, '{\"full_name\": \"Jayantha Fernando\", \"email\": \"jayantha.fernando.lift@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Lift\", \"employee_code\": \"HFT-E-LIFT-03\"}', 'Technician account created for Lift support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 08:51:00'),
(500, 15, 'User Created', 'users', '374', NULL, '{\"full_name\": \"Jeewan Gunawardena\", \"email\": \"jeewan.gunawardena.clean@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Cleaning\", \"employee_code\": \"HFT-C-CLEAN-06\"}', 'Technician account created for Cleaning support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 09:21:00'),
(501, 15, 'User Created', 'users', '375', NULL, '{\"full_name\": \"Kanishka Samarasinghe\", \"email\": \"kanishka.samarasinghe.sec@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Security and Access\", \"employee_code\": \"HFT-B-SEC-13\"}', 'Technician account created for Security and Access support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 15:01:00'),
(502, 15, 'User Created', 'users', '376', NULL, '{\"full_name\": \"Kasun Maduranga\", \"email\": \"kasun.maduranga.sec@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Security and Access\", \"employee_code\": \"HFT-A-SEC-13\"}', 'Technician account created for Security and Access support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 10:31:00'),
(503, 15, 'User Created', 'users', '377', NULL, '{\"full_name\": \"Kaveen Bandara\", \"email\": \"kaveen.bandara.ac@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Air Conditioning\", \"employee_code\": \"HFT-E-AC-04\"}', 'Technician account created for Air Conditioning support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:01:00'),
(504, 15, 'User Created', 'users', '378', NULL, '{\"full_name\": \"Kelum Senanayake\", \"email\": \"kelum.senanayake.pest@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Pest Control\", \"employee_code\": \"HFT-C-PEST-07\"}', 'Technician account created for Pest Control support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 09:31:00'),
(505, 15, 'User Created', 'users', '379', NULL, '{\"full_name\": \"Lahiru Senanayake\", \"email\": \"lahiru.senanayake.pest@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Pest Control\", \"employee_code\": \"HFT-A-PEST-07\"}', 'Technician account created for Pest Control support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 09:31:00'),
(506, 15, 'User Created', 'users', '380', NULL, '{\"full_name\": \"Lakmal Rathnayake\", \"email\": \"lakmal.rathnayake.carp@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Carpentry\", \"employee_code\": \"HFT-C-CARP-08\"}', 'Technician account created for Carpentry support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 09:41:00'),
(507, 15, 'User Created', 'users', '381', NULL, '{\"full_name\": \"Lasantha Jayawardena\", \"email\": \"lasantha.jayawardena.drain@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Drainage\", \"employee_code\": \"HFT-E-DRAIN-05\"}', 'Technician account created for Drainage support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:11:00'),
(508, 15, 'User Created', 'users', '382', NULL, '{\"full_name\": \"Madhuka Senanayake\", \"email\": \"madhuka.senanayake.pest@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Pest Control\", \"employee_code\": \"HFT-B-PEST-07\"}', 'Technician account created for Pest Control support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 14:01:00'),
(509, 15, 'User Created', 'users', '383', NULL, '{\"full_name\": \"Mahesh Karunaratne\", \"email\": \"mahesh.karunaratne.gas@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Gas\", \"employee_code\": \"HFT-A-GAS-11\"}', 'Technician account created for Gas support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 10:11:00'),
(510, 15, 'User Created', 'users', '384', NULL, '{\"full_name\": \"Malinga Gunawardena\", \"email\": \"malinga.gunawardena.clean@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Cleaning\", \"employee_code\": \"HFT-E-CLEAN-06\"}', 'Technician account created for Cleaning support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:21:00'),
(511, 15, 'User Created', 'users', '385', NULL, '{\"full_name\": \"Manjula Herath\", \"email\": \"manjula.herath.fire@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Fire and Safety\", \"employee_code\": \"HFT-B-FIRE-10\"}', 'Technician account created for Fire and Safety support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 14:31:00'),
(512, 15, 'User Created', 'users', '386', NULL, '{\"full_name\": \"Milan Peiris\", \"email\": \"milan.peiris.other@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Other\", \"employee_code\": \"HFT-C-OTHER-09\"}', 'Technician account created for Other support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 09:51:00'),
(513, 15, 'User Created', 'users', '387', NULL, '{\"full_name\": \"Nalaka Herath\", \"email\": \"nalaka.herath.fire@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Fire and Safety\", \"employee_code\": \"HFT-C-FIRE-10\"}', 'Technician account created for Fire and Safety support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 10:01:00'),
(514, 15, 'User Created', 'users', '388', NULL, '{\"full_name\": \"Naveen Senanayake\", \"email\": \"naveen.senanayake.pest@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Pest Control\", \"employee_code\": \"HFT-E-PEST-07\"}', 'Technician account created for Pest Control support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:31:00'),
(515, 15, 'User Created', 'users', '389', NULL, '{\"full_name\": \"Osanda Rathnayake\", \"email\": \"osanda.rathnayake.carp@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Carpentry\", \"employee_code\": \"HFT-E-CARP-08\"}', 'Technician account created for Carpentry support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:41:00'),
(516, 15, 'User Created', 'users', '390', NULL, '{\"full_name\": \"Oshan Dissanayake\", \"email\": \"oshan.dissanayake.gas@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Gas\", \"employee_code\": \"HFT-C-GAS-11\"}', 'Technician account created for Gas support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 10:11:00'),
(517, 15, 'User Created', 'users', '391', NULL, '{\"full_name\": \"Prabath Wijekoon\", \"email\": \"prabath.wijekoon.struct@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Structural\", \"employee_code\": \"HFT-C-STRUCT-12\"}', 'Technician account created for Structural support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 10:21:00'),
(518, 15, 'User Created', 'users', '392', NULL, '{\"full_name\": \"Pradeep Rajapaksha\", \"email\": \"pradeep.rajapaksha.fire@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Fire and Safety\", \"employee_code\": \"HFT-A-FIRE-10\"}', 'Technician account created for Fire and Safety support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 10:01:00'),
(519, 15, 'User Created', 'users', '393', NULL, '{\"full_name\": \"Pubudu Peiris\", \"email\": \"pubudu.peiris.other@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Other\", \"employee_code\": \"HFT-E-OTHER-09\"}', 'Technician account created for Other support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:51:00'),
(520, 15, 'User Created', 'users', '394', NULL, '{\"full_name\": \"Ranga Samarasinghe\", \"email\": \"ranga.samarasinghe.sec@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block C\", \"category\": \"Security and Access\", \"employee_code\": \"HFT-C-SEC-13\"}', 'Technician account created for Security and Access support in Block C during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 10:31:00'),
(521, 15, 'User Created', 'users', '395', NULL, '{\"full_name\": \"Ravimal Herath\", \"email\": \"ravimal.herath.fire@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Fire and Safety\", \"employee_code\": \"HFT-E-FIRE-10\"}', 'Technician account created for Fire and Safety support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 10:01:00'),
(522, 15, 'User Created', 'users', '396', NULL, '{\"full_name\": \"Roshan Fernando\", \"email\": \"roshan.fernando.lift@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Lift\", \"employee_code\": \"HFT-B-LIFT-03\"}', 'Technician account created for Lift support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 13:21:00'),
(523, 15, 'User Created', 'users', '397', NULL, '{\"full_name\": \"Ruwan Bandara\", \"email\": \"ruwan.bandara.carp@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Carpentry\", \"employee_code\": \"HFT-A-CARP-08\"}', 'Technician account created for Carpentry support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 09:41:00'),
(524, 15, 'User Created', 'users', '398', NULL, '{\"full_name\": \"Sachith De Silva\", \"email\": \"sachith.de.silva.struct@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Structural\", \"employee_code\": \"HFT-A-STRUCT-12\"}', 'Technician account created for Structural support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 10:21:00'),
(525, 15, 'User Created', 'users', '399', NULL, '{\"full_name\": \"Sahan Silva\", \"email\": \"sahan.silva.plumb@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Plumbing\", \"employee_code\": \"HFT-B-PLUMB-02\"}', 'Technician account created for Plumbing support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 13:11:00'),
(526, 15, 'User Created', 'users', '400', NULL, '{\"full_name\": \"Sajith Dissanayake\", \"email\": \"sajith.dissanayake.gas@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Gas\", \"employee_code\": \"HFT-E-GAS-11\"}', 'Technician account created for Gas support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 10:11:00'),
(527, 15, 'User Created', 'users', '401', NULL, '{\"full_name\": \"Sameera Gunasekara\", \"email\": \"sameera.gunasekara.clean@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Cleaning\", \"employee_code\": \"HFT-B-CLEAN-06\"}', 'Technician account created for Cleaning support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 13:51:00'),
(528, 15, 'User Created', 'users', '402', NULL, '{\"full_name\": \"Sampath Perera\", \"email\": \"sampath.perera.elec@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Electrical\", \"employee_code\": \"HFT-D-ELEC-01\"}', 'Technician account created for Electrical support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 13:01:00'),
(529, 15, 'User Created', 'users', '403', NULL, '{\"full_name\": \"Sanjaya Peiris\", \"email\": \"sanjaya.peiris.other@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Other\", \"employee_code\": \"HFT-B-OTHER-09\"}', 'Technician account created for Other support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 14:21:00'),
(530, 15, 'User Created', 'users', '404', NULL, '{\"full_name\": \"Supun Jayasinghe\", \"email\": \"supun.jayasinghe.lift@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Lift\", \"employee_code\": \"HFT-A-LIFT-03\"}', 'Technician account created for Lift support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 08:51:00'),
(531, 15, 'User Created', 'users', '405', NULL, '{\"full_name\": \"Nuwan Silva\", \"email\": \"tech@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Electrical\", \"employee_code\": \"HFT-A-ELEC-01\"}', 'Technician account created for Electrical support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 08:31:00'),
(532, 15, 'User Created', 'users', '406', NULL, '{\"full_name\": \"Tharanga Wijekoon\", \"email\": \"tharanga.wijekoon.struct@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Structural\", \"employee_code\": \"HFT-E-STRUCT-12\"}', 'Technician account created for Structural support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 10:21:00'),
(533, 15, 'User Created', 'users', '407', NULL, '{\"full_name\": \"Tharindu Kumara\", \"email\": \"tharindu.kumara.clean@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block A\", \"category\": \"Cleaning\", \"employee_code\": \"HFT-A-CLEAN-06\"}', 'Technician account created for Cleaning support in Block A during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 09:21:00'),
(534, 15, 'User Created', 'users', '408', NULL, '{\"full_name\": \"Thilak Silva\", \"email\": \"thilak.silva.plumb@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Plumbing\", \"employee_code\": \"HFT-D-PLUMB-02\"}', 'Technician account created for Plumbing support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 13:11:00'),
(535, 15, 'User Created', 'users', '409', NULL, '{\"full_name\": \"Udara Jayasinghe\", \"email\": \"udara.jayasinghe.drain@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block B\", \"category\": \"Drainage\", \"employee_code\": \"HFT-B-DRAIN-05\"}', 'Technician account created for Drainage support in Block B during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-19 13:41:00'),
(536, 15, 'User Created', 'users', '410', NULL, '{\"full_name\": \"Udaya Samarasinghe\", \"email\": \"udaya.samarasinghe.sec@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block E\", \"category\": \"Security and Access\", \"employee_code\": \"HFT-E-SEC-13\"}', 'Technician account created for Security and Access support in Block E during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 10:31:00'),
(537, 15, 'User Created', 'users', '411', NULL, '{\"full_name\": \"Upul Fernando\", \"email\": \"upul.fernando.lift@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Lift\", \"employee_code\": \"HFT-D-LIFT-03\"}', 'Technician account created for Lift support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 13:21:00'),
(538, 15, 'User Created', 'users', '412', NULL, '{\"full_name\": \"Vajira Bandara\", \"email\": \"vajira.bandara.ac@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Air Conditioning\", \"employee_code\": \"HFT-D-AC-04\"}', 'Technician account created for Air Conditioning support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 13:31:00'),
(539, 15, 'User Created', 'users', '413', NULL, '{\"full_name\": \"Wasantha Jayawardena\", \"email\": \"wasantha.jayawardena.drain@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Drainage\", \"employee_code\": \"HFT-D-DRAIN-05\"}', 'Technician account created for Drainage support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 13:41:00'),
(540, 15, 'User Created', 'users', '414', NULL, '{\"full_name\": \"Yohan Gunawardena\", \"email\": \"yohan.gunawardena.clean@helafixit.lk\", \"role\": \"Technician\", \"building\": \"Block D\", \"category\": \"Cleaning\", \"employee_code\": \"HFT-D-CLEAN-06\"}', 'Technician account created for Cleaning support in Block D during the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 13:51:00'),
(603, 15, 'User Created', 'users', '477', NULL, '{\"full_name\": \"Dulanjana Silva\", \"email\": \"dulanjana.silva.sys@helafixit.lk\", \"role\": \"System Admin\", \"scope\": \"Hela Residence\"}', 'System administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 10:16:00'),
(604, 15, 'User Created', 'users', '478', NULL, '{\"full_name\": \"Hasini Wickramasinghe\", \"email\": \"hasini.wickramasinghe.sys@helafixit.lk\", \"role\": \"System Admin\", \"scope\": \"Hela Residence\"}', 'System administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 10:01:00'),
(605, 15, 'User Created', 'users', '479', NULL, '{\"full_name\": \"Malith Jayawardena\", \"email\": \"malith.jayawardena.sys@helafixit.lk\", \"role\": \"System Admin\", \"scope\": \"Hela Residence\"}', 'System administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 09:16:00'),
(606, 15, 'User Created', 'users', '480', NULL, '{\"full_name\": \"Nipuni Fernando\", \"email\": \"nipuni.fernando.sys@helafixit.lk\", \"role\": \"System Admin\", \"scope\": \"Hela Residence\"}', 'System administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 09:31:00'),
(607, 15, 'User Created', 'users', '481', NULL, '{\"full_name\": \"Ravini Gunasekara\", \"email\": \"ravini.gunasekara.sys@helafixit.lk\", \"role\": \"System Admin\", \"scope\": \"Hela Residence\"}', 'System administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 10:31:00'),
(608, 15, 'User Created', 'users', '482', NULL, '{\"full_name\": \"Kasun Wijesinghe\", \"email\": \"sadmin@helafixit.lk\", \"role\": \"System Admin\", \"scope\": \"Hela Residence\"}', 'System administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 09:01:00'),
(609, 15, 'User Created', 'users', '483', NULL, '{\"full_name\": \"Sajith Bandara\", \"email\": \"sajith.bandara.sys@helafixit.lk\", \"role\": \"System Admin\", \"scope\": \"Hela Residence\"}', 'System administrator account created during the HelaFixIt AI user setup in the previous week.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 09:46:00'),
(610, 15, 'Initial Resident Provisioning Completed', 'user_management', 'RESIDENT-INITIAL-20260817', NULL, '{\"resident_count\": 38, \"buildings\": 5}', 'Initial batch of 38 synthetic resident accounts was created across all five apartment buildings.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-17 15:10:00'),
(611, 15, 'Apartment Admin Provisioning Completed', 'user_management', 'ADMIN-INITIAL-20260818', NULL, '{\"apartment_admin_count\": 10, \"admins_per_building\": 2, \"buildings\": 5}', 'Created 10 apartment administrator accounts with two administrators assigned to each building.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 11:30:00'),
(612, 15, 'Technician Provisioning Completed', 'user_management', 'TECH-INITIAL-20260821', NULL, '{\"technician_count\": 65, \"categories_per_building\": 13, \"buildings\": 5}', 'Created one technician for every maintenance category in every apartment building.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 12:00:00'),
(613, 15, 'System Admin Provisioning Completed', 'user_management', 'SADMIN-INITIAL-20260822', NULL, '{\"system_admin_count\": 8, \"preserved_owner\": \"rakindufernando@gmail.com\"}', 'Completed the system administration team with eight active system administrators including the preserved owner account.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 11:00:00');
INSERT INTO `audit_logs` (`audit_id`, `user_id`, `action_type`, `entity_type`, `entity_id`, `old_value`, `new_value`, `reason`, `ip_address`, `user_agent`, `created_at`) VALUES
(614, 15, 'User Provisioning Review Completed', 'user_management', 'USER-REVIEW-20260823', NULL, '{\"total_users\": 143, \"residents\": 60, \"apartment_admins\": 10, \"technicians\": 65, \"system_admins\": 8}', 'All 143 active user accounts were reviewed after resident expansion. The database contains 60 residents, 10 apartment administrators, 65 technicians and 8 system administrators with building and role coverage checked.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-23 17:00:00'),
(953, 297, 'Ticket Submitted', 'maintenance_tickets', '65', NULL, '{\"ticket_number\": \"TCK-HF-260823-A-REV01\", \"building\": \"Block A\", \"subject\": \"Bedroom door hinge is loose\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 14:05:00'),
(954, 285, 'Ticket Submitted', 'maintenance_tickets', '66', NULL, '{\"ticket_number\": \"TCK-HF-260823-A-UNA01\", \"building\": \"Block A\", \"subject\": \"Kitchen area gas smell\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 15:10:00'),
(955, 277, 'Ticket Submitted', 'maintenance_tickets', '67', NULL, '{\"ticket_number\": \"TCK-HF-260823-A-ASG01\", \"building\": \"Block A\", \"subject\": \"Bathroom tap is leaking\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 08:15:00'),
(956, 280, 'Ticket Submitted', 'maintenance_tickets', '68', NULL, '{\"ticket_number\": \"TCK-HF-260822-A-PRG01\", \"building\": \"Block A\", \"subject\": \"Living room AC is not cooling\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 14:20:00'),
(957, 291, 'Ticket Submitted', 'maintenance_tickets', '69', NULL, '{\"ticket_number\": \"TCK-HF-260821-A-CMP01\", \"building\": \"Block A\", \"subject\": \"ස්ටඩි ටේබල් අසල සොකට් එකෙන් ස්පාර්ක් වෙනවා\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-21 13:10:00'),
(958, 303, 'Ticket Submitted', 'maintenance_tickets', '70', NULL, '{\"ticket_number\": \"TCK-HF-260823-B-REV01\", \"building\": \"Block B\", \"subject\": \"කසළ ප්‍රදේශය අසල කැරපොත්තන් පේනවා\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 14:15:00'),
(959, 306, 'Ticket Submitted', 'maintenance_tickets', '71', NULL, '{\"ticket_number\": \"TCK-HF-260823-B-UNA01\", \"building\": \"Block B\", \"subject\": \"Lift stopped between floors\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 15:20:00'),
(960, 272, 'Ticket Submitted', 'maintenance_tickets', '72', NULL, '{\"ticket_number\": \"TCK-HF-260823-B-ASG01\", \"building\": \"Block B\", \"subject\": \"Access card reader is not working\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 08:25:00'),
(961, 299, 'Ticket Submitted', 'maintenance_tickets', '73', NULL, '{\"ticket_number\": \"TCK-HF-260822-B-PRG01\", \"building\": \"Block B\", \"subject\": \"Common drain is overflowing\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 14:35:00'),
(962, 294, 'Ticket Submitted', 'maintenance_tickets', '74', NULL, '{\"ticket_number\": \"TCK-HF-260821-B-CMP01\", \"building\": \"Block B\", \"subject\": \"Oil spill in corridor\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-21 13:25:00'),
(963, 308, 'Ticket Submitted', 'maintenance_tickets', '75', NULL, '{\"ticket_number\": \"TCK-HF-260823-C-REV01\", \"building\": \"Block C\", \"subject\": \"New crack on bedroom wall\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 14:25:00'),
(964, 286, 'Ticket Submitted', 'maintenance_tickets', '76', NULL, '{\"ticket_number\": \"TCK-HF-260823-C-UNA01\", \"building\": \"Block C\", \"subject\": \"Smoke smell near electrical room\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 15:30:00'),
(965, 281, 'Ticket Submitted', 'maintenance_tickets', '77', NULL, '{\"ticket_number\": \"TCK-HF-260823-C-ASG01\", \"building\": \"Block C\", \"subject\": \"Window latch is broken\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 08:35:00'),
(966, 296, 'Ticket Submitted', 'maintenance_tickets', '78', NULL, '{\"ticket_number\": \"TCK-HF-260822-C-PRG01\", \"building\": \"Block C\", \"subject\": \"Kitchen sink pipe is leaking\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 14:50:00'),
(967, 274, 'Ticket Submitted', 'maintenance_tickets', '79', NULL, '{\"ticket_number\": \"TCK-HF-260821-C-CMP01\", \"building\": \"Block C\", \"subject\": \"නිදන කාමරයේ AC එකෙන් වතුර බේරෙනවා\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-21 13:40:00'),
(968, 304, 'Ticket Submitted', 'maintenance_tickets', '80', NULL, '{\"ticket_number\": \"TCK-HF-260823-D-REV01\", \"building\": \"Block D\", \"subject\": \"Water pump is making a loud noise\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 14:35:00'),
(969, 279, 'Ticket Submitted', 'maintenance_tickets', '81', NULL, '{\"ticket_number\": \"TCK-HF-260823-D-UNA01\", \"building\": \"Block D\", \"subject\": \"Water close to electrical panel\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 15:40:00'),
(970, 276, 'Ticket Submitted', 'maintenance_tickets', '82', NULL, '{\"ticket_number\": \"TCK-HF-260823-D-ASG01\", \"building\": \"Block D\", \"subject\": \"Garbage room needs cleaning\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 08:45:00'),
(971, 301, 'Ticket Submitted', 'maintenance_tickets', '83', NULL, '{\"ticket_number\": \"TCK-HF-260822-D-PRG01\", \"building\": \"Block D\", \"subject\": \"Ant problem in pantry\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 15:05:00'),
(972, 284, 'Ticket Submitted', 'maintenance_tickets', '84', NULL, '{\"ticket_number\": \"TCK-HF-260821-D-CMP01\", \"building\": \"Block D\", \"subject\": \"සිවිලිමේ ප්ලාස්ටර් ඉරිතැලීලා\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-21 13:55:00'),
(973, 273, 'Ticket Submitted', 'maintenance_tickets', '85', NULL, '{\"ticket_number\": \"TCK-HF-260823-E-REV01\", \"building\": \"Block E\", \"subject\": \"Lift is making an unusual noise\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 14:45:00'),
(974, 287, 'Ticket Submitted', 'maintenance_tickets', '86', NULL, '{\"ticket_number\": \"TCK-HF-260823-E-UNA01\", \"building\": \"Block E\", \"subject\": \"Strong gas smell in pantry\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 15:50:00'),
(975, 302, 'Ticket Submitted', 'maintenance_tickets', '87', NULL, '{\"ticket_number\": \"TCK-HF-260823-E-ASG01\", \"building\": \"Block E\", \"subject\": \"Bedroom circuit keeps tripping\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 08:55:00'),
(976, 298, 'Ticket Submitted', 'maintenance_tickets', '88', NULL, '{\"ticket_number\": \"TCK-HF-260822-E-PRG01\", \"building\": \"Block E\", \"subject\": \"Parking gate is not closing\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 15:20:00'),
(977, 293, 'Ticket Submitted', 'maintenance_tickets', '89', NULL, '{\"ticket_number\": \"TCK-HF-260821-E-CMP01\", \"building\": \"Block E\", \"subject\": \"ටොයිලට් සිස්ටර්න් එකෙන් වතුර කාන්දු වුණා\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-21 14:10:00'),
(978, 292, 'Ticket Submitted', 'maintenance_tickets', '90', NULL, '{\"ticket_number\": \"TCK-HF-260820-A-REV02\", \"building\": \"Block A\", \"subject\": \"Water pump pressure is unstable\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-20 10:20:00'),
(979, 290, 'Ticket Submitted', 'maintenance_tickets', '91', NULL, '{\"ticket_number\": \"TCK-HF-260820-D-UNA02\", \"building\": \"Block D\", \"subject\": \"Fire alarm panel shows fault\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-20 11:15:00'),
(980, 289, 'Ticket Submitted', 'maintenance_tickets', '92', NULL, '{\"ticket_number\": \"TCK-HF-260820-E-ASG02\", \"building\": \"Block E\", \"subject\": \"Balcony drain is blocked\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-20 09:10:00'),
(984, 297, 'AI Analysis', 'maintenance_tickets', '65', NULL, '{\"category\": \"Carpentry\", \"priority\": \"Low\", \"risk_score\": 24.00, \"risk_level\": \"Low\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 14:05:02'),
(985, 285, 'AI Analysis', 'maintenance_tickets', '66', NULL, '{\"category\": \"Gas\", \"priority\": \"Emergency\", \"risk_score\": 97.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 15:10:02'),
(986, 277, 'AI Analysis', 'maintenance_tickets', '67', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 38.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 08:15:02'),
(987, 280, 'AI Analysis', 'maintenance_tickets', '68', NULL, '{\"category\": \"Air Conditioning\", \"priority\": \"Medium\", \"risk_score\": 44.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 14:20:02'),
(988, 291, 'AI Analysis', 'maintenance_tickets', '69', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 76.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-21 13:10:02'),
(989, 303, 'AI Analysis', 'maintenance_tickets', '70', NULL, '{\"category\": \"Pest Control\", \"priority\": \"Low\", \"risk_score\": 27.00, \"risk_level\": \"Low\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 14:15:02'),
(990, 306, 'AI Analysis', 'maintenance_tickets', '71', NULL, '{\"category\": \"Lift\", \"priority\": \"Emergency\", \"risk_score\": 94.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 15:20:02'),
(991, 272, 'AI Analysis', 'maintenance_tickets', '72', NULL, '{\"category\": \"Security and Access\", \"priority\": \"High\", \"risk_score\": 63.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 08:25:02'),
(992, 299, 'AI Analysis', 'maintenance_tickets', '73', NULL, '{\"category\": \"Drainage\", \"priority\": \"High\", \"risk_score\": 72.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 14:35:02'),
(993, 294, 'AI Analysis', 'maintenance_tickets', '74', NULL, '{\"category\": \"Cleaning\", \"priority\": \"Low\", \"risk_score\": 29.00, \"risk_level\": \"Low\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-21 13:25:02'),
(994, 308, 'AI Analysis', 'maintenance_tickets', '75', NULL, '{\"category\": \"Structural\", \"priority\": \"High\", \"risk_score\": 62.00, \"risk_level\": \"High\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 14:25:02'),
(995, 286, 'AI Analysis', 'maintenance_tickets', '76', NULL, '{\"category\": \"Fire and Safety\", \"priority\": \"Emergency\", \"risk_score\": 100.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 15:30:02'),
(996, 281, 'AI Analysis', 'maintenance_tickets', '77', NULL, '{\"category\": \"Carpentry\", \"priority\": \"Low\", \"risk_score\": 31.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 08:35:02'),
(997, 296, 'AI Analysis', 'maintenance_tickets', '78', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 14:50:02'),
(998, 274, 'AI Analysis', 'maintenance_tickets', '79', NULL, '{\"category\": \"Air Conditioning\", \"priority\": \"Medium\", \"risk_score\": 36.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-21 13:40:02'),
(999, 304, 'AI Analysis', 'maintenance_tickets', '80', NULL, '{\"category\": \"Other\", \"priority\": \"Medium\", \"risk_score\": 41.00, \"risk_level\": \"Medium\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 14:35:02'),
(1000, 279, 'AI Analysis', 'maintenance_tickets', '81', NULL, '{\"category\": \"Electrical\", \"priority\": \"Emergency\", \"risk_score\": 96.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 15:40:02'),
(1001, 276, 'AI Analysis', 'maintenance_tickets', '82', NULL, '{\"category\": \"Cleaning\", \"priority\": \"Low\", \"risk_score\": 21.00, \"risk_level\": \"Low\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 08:45:02'),
(1002, 301, 'AI Analysis', 'maintenance_tickets', '83', NULL, '{\"category\": \"Pest Control\", \"priority\": \"Medium\", \"risk_score\": 39.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 15:05:02'),
(1003, 284, 'AI Analysis', 'maintenance_tickets', '84', NULL, '{\"category\": \"Structural\", \"priority\": \"High\", \"risk_score\": 68.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-21 13:55:02'),
(1004, 273, 'AI Analysis', 'maintenance_tickets', '85', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 58.00, \"risk_level\": \"Medium\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 14:45:02'),
(1005, 287, 'AI Analysis', 'maintenance_tickets', '86', NULL, '{\"category\": \"Gas\", \"priority\": \"Emergency\", \"risk_score\": 99.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 15:50:02'),
(1006, 302, 'AI Analysis', 'maintenance_tickets', '87', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 59.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 08:55:02'),
(1007, 298, 'AI Analysis', 'maintenance_tickets', '88', NULL, '{\"category\": \"Security and Access\", \"priority\": \"High\", \"risk_score\": 57.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 15:20:02'),
(1008, 293, 'AI Analysis', 'maintenance_tickets', '89', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 35.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-21 14:10:02'),
(1009, 292, 'AI Analysis', 'maintenance_tickets', '90', NULL, '{\"category\": \"Other\", \"priority\": \"Medium\", \"risk_score\": 46.00, \"risk_level\": \"Medium\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-20 10:20:02'),
(1010, 290, 'AI Analysis', 'maintenance_tickets', '91', NULL, '{\"category\": \"Fire and Safety\", \"priority\": \"Emergency\", \"risk_score\": 98.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-20 11:15:02'),
(1011, 289, 'AI Analysis', 'maintenance_tickets', '92', NULL, '{\"category\": \"Drainage\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-20 09:10:02'),
(1015, 335, 'Ticket Review', 'maintenance_tickets', '67', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 2, \"priority\": \"Medium\", \"risk_score\": 38.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-23 08:45:00'),
(1016, 335, 'Ticket Review', 'maintenance_tickets', '68', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 4, \"priority\": \"Medium\", \"risk_score\": 44.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 15:00:00'),
(1017, 335, 'Ticket Review', 'maintenance_tickets', '69', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 1, \"priority\": \"High\", \"risk_score\": 76.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 13:25:00'),
(1018, 339, 'Ticket Review', 'maintenance_tickets', '72', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 13, \"priority\": \"High\", \"risk_score\": 63.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-23 08:55:00'),
(1019, 339, 'Ticket Review', 'maintenance_tickets', '73', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 5, \"priority\": \"High\", \"risk_score\": 72.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 15:10:00'),
(1020, 339, 'Ticket Review', 'maintenance_tickets', '74', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 6, \"priority\": \"Low\", \"risk_score\": 29.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 13:40:00'),
(1021, 336, 'Ticket Review', 'maintenance_tickets', '77', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 8, \"priority\": \"Low\", \"risk_score\": 31.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-23 09:05:00'),
(1022, 336, 'Ticket Review', 'maintenance_tickets', '78', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 2, \"priority\": \"Medium\", \"risk_score\": 48.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 15:25:00'),
(1023, 336, 'Ticket Review', 'maintenance_tickets', '79', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 4, \"priority\": \"Medium\", \"risk_score\": 36.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 13:55:00'),
(1024, 337, 'Ticket Review', 'maintenance_tickets', '82', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 6, \"priority\": \"Low\", \"risk_score\": 21.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-23 09:15:00'),
(1025, 337, 'Ticket Review', 'maintenance_tickets', '83', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 7, \"priority\": \"Medium\", \"risk_score\": 39.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 15:40:00'),
(1026, 337, 'Ticket Review', 'maintenance_tickets', '84', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 12, \"priority\": \"High\", \"risk_score\": 68.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 14:10:00'),
(1027, 338, 'Ticket Review', 'maintenance_tickets', '87', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 1, \"priority\": \"High\", \"risk_score\": 59.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-23 09:25:00'),
(1028, 338, 'Ticket Review', 'maintenance_tickets', '88', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 13, \"priority\": \"High\", \"risk_score\": 57.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 15:55:00'),
(1029, 338, 'Ticket Review', 'maintenance_tickets', '89', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 2, \"priority\": \"Medium\", \"risk_score\": 35.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 14:25:00'),
(1030, 338, 'Ticket Review', 'maintenance_tickets', '92', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 5, \"priority\": \"High\", \"risk_score\": 64.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 09:35:00'),
(1046, 335, 'Technician Assigned', 'maintenance_tickets', '67', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 157, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-23 09:00:00'),
(1047, 335, 'Technician Assigned', 'maintenance_tickets', '68', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 163, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 15:15:00'),
(1048, 335, 'Technician Assigned', 'maintenance_tickets', '69', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 207, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 13:35:00'),
(1049, 339, 'Technician Assigned', 'maintenance_tickets', '72', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 177, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-23 09:10:00'),
(1050, 339, 'Technician Assigned', 'maintenance_tickets', '73', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 211, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 15:25:00'),
(1051, 339, 'Technician Assigned', 'maintenance_tickets', '74', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 203, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 13:50:00'),
(1052, 336, 'Technician Assigned', 'maintenance_tickets', '77', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 182, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-23 09:20:00'),
(1053, 336, 'Technician Assigned', 'maintenance_tickets', '78', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 156, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 15:40:00'),
(1054, 336, 'Technician Assigned', 'maintenance_tickets', '79', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 169, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 14:05:00'),
(1055, 337, 'Technician Assigned', 'maintenance_tickets', '82', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 216, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-23 09:30:00'),
(1056, 337, 'Technician Assigned', 'maintenance_tickets', '83', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 154, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 15:55:00'),
(1057, 337, 'Technician Assigned', 'maintenance_tickets', '84', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 166, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 14:20:00'),
(1058, 338, 'Technician Assigned', 'maintenance_tickets', '87', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 170, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-23 09:40:00'),
(1059, 338, 'Technician Assigned', 'maintenance_tickets', '88', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 212, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 16:10:00'),
(1060, 338, 'Technician Assigned', 'maintenance_tickets', '89', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 172, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 14:35:00'),
(1061, 338, 'Technician Assigned', 'maintenance_tickets', '92', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 183, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-20 09:50:00'),
(1077, 361, 'Job Accepted', 'maintenance_tickets', '68', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-22 15:40:00'),
(1078, 405, 'Job Accepted', 'maintenance_tickets', '69', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 13:42:00'),
(1079, 409, 'Job Accepted', 'maintenance_tickets', '73', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-22 15:45:00'),
(1080, 401, 'Job Accepted', 'maintenance_tickets', '74', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 13:58:00'),
(1081, 354, 'Job Accepted', 'maintenance_tickets', '78', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-22 16:00:00'),
(1082, 367, 'Job Accepted', 'maintenance_tickets', '79', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 14:13:00'),
(1083, 352, 'Job Accepted', 'maintenance_tickets', '83', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-22 16:15:00'),
(1084, 364, 'Job Accepted', 'maintenance_tickets', '84', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 14:28:00'),
(1085, 410, 'Job Accepted', 'maintenance_tickets', '88', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-22 16:30:00'),
(1086, 370, 'Job Accepted', 'maintenance_tickets', '89', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 14:43:00'),
(1092, 361, 'Job Started', 'maintenance_tickets', '68', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-23 09:10:00'),
(1093, 405, 'Job Started', 'maintenance_tickets', '69', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 13:45:00'),
(1094, 409, 'Job Started', 'maintenance_tickets', '73', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-23 09:25:00'),
(1095, 401, 'Job Started', 'maintenance_tickets', '74', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 14:00:00'),
(1096, 354, 'Job Started', 'maintenance_tickets', '78', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-23 09:40:00'),
(1097, 367, 'Job Started', 'maintenance_tickets', '79', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 14:15:00'),
(1098, 352, 'Job Started', 'maintenance_tickets', '83', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-23 09:55:00'),
(1099, 364, 'Job Started', 'maintenance_tickets', '84', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 14:30:00'),
(1100, 410, 'Job Started', 'maintenance_tickets', '88', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-23 10:10:00'),
(1101, 370, 'Job Started', 'maintenance_tickets', '89', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 14:45:00'),
(1107, 405, 'Job Resolved', 'maintenance_tickets', '69', '{\"status\": \"In Progress\"}', '{\"status\": \"Resolved\", \"completion_note\": \"Damaged socket replaced and wiring connections checked. Power was tested and restored safely.\"}', 'Technician completed the maintenance work and recorded the resolution in the system.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 14:25:00'),
(1108, 401, 'Job Resolved', 'maintenance_tickets', '74', '{\"status\": \"In Progress\"}', '{\"status\": \"Resolved\", \"completion_note\": \"Spill was cleaned, the floor was degreased and a temporary warning sign was used until the area dried.\"}', 'Technician completed the maintenance work and recorded the resolution in the system.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 14:35:00'),
(1109, 367, 'Job Resolved', 'maintenance_tickets', '79', '{\"status\": \"In Progress\"}', '{\"status\": \"Resolved\", \"completion_note\": \"Drain pipe blockage cleared, filter cleaned and AC drainage tested with no further leakage.\"}', 'Technician completed the maintenance work and recorded the resolution in the system.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 15:00:00'),
(1110, 364, 'Job Resolved', 'maintenance_tickets', '84', '{\"status\": \"In Progress\"}', '{\"status\": \"Resolved\", \"completion_note\": \"Loose plaster removed, area inspected and repaired. No deeper structural movement was identified during the inspection.\"}', 'Technician completed the maintenance work and recorded the resolution in the system.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 15:20:00'),
(1111, 370, 'Job Resolved', 'maintenance_tickets', '89', '{\"status\": \"In Progress\"}', '{\"status\": \"Resolved\", \"completion_note\": \"Cistern inlet valve adjusted and worn seal replaced. Water flow was tested and the leak stopped.\"}', 'Technician completed the maintenance work and recorded the resolution in the system.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 15:30:00'),
(1114, 335, 'Emergency Assignment Pending', 'maintenance_tickets', '66', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 97.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 15:10:03'),
(1115, 339, 'Emergency Assignment Pending', 'maintenance_tickets', '71', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 94.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 15:20:03'),
(1116, 336, 'Emergency Assignment Pending', 'maintenance_tickets', '76', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 100.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 15:30:03'),
(1117, 337, 'Emergency Assignment Pending', 'maintenance_tickets', '81', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 96.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 15:40:03'),
(1118, 338, 'Emergency Assignment Pending', 'maintenance_tickets', '86', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 99.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 15:50:03'),
(1119, 337, 'Emergency Assignment Pending', 'maintenance_tickets', '91', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 98.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-20 11:15:03'),
(1121, 15, 'Maintenance Ticket Records Created', 'ticket_batch', 'TICKETS-AUG2026', NULL, '{\"total_tickets\": 28, \"awaiting_admin_review\": 6, \"urgent_unassigned\": 6, \"assigned_jobs\": 6, \"in_progress_jobs\": 5, \"completed_jobs\": 5, \"buildings\": 5, \"period_start\": \"2026-08-20\", \"period_end\": \"2026-08-23\", \"english_tickets\": 7, \"sinhala_tickets\": 6, \"singlish_tickets\": 10, \"mixed_tickets\": 5}', 'Twenty-eight maintenance ticket records, including admin review, pending assignment, assigned, in progress and completed workflows, were created during the previous week in the HelaFixIt AI system.', '127.0.0.1', 'HelaFixIt AI System Admin Console', '2026-08-23 16:30:00'),
(1122, 285, 'Ticket Submitted', 'maintenance_tickets', '96', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML001\", \"building\": \"Block A\", \"subject\": \"Kitchen sink pipe is leaking\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 13:00:00'),
(1123, 277, 'Ticket Submitted', 'maintenance_tickets', '97', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML002\", \"building\": \"Block A\", \"subject\": \"Corridor light keeps flickering\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 13:17:00'),
(1124, 280, 'Ticket Submitted', 'maintenance_tickets', '98', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML003\", \"building\": \"Block A\", \"subject\": \"Bedroom AC is dripping water\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 13:34:00'),
(1125, 291, 'Ticket Submitted', 'maintenance_tickets', '99', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML004\", \"building\": \"Block A\", \"subject\": \"Parking gate sensor is unreliable\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 13:51:00'),
(1126, 292, 'Ticket Submitted', 'maintenance_tickets', '100', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML005\", \"building\": \"Block A\", \"subject\": \"Bathroom drain is very slow\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 14:08:00'),
(1127, 288, 'Ticket Submitted', 'maintenance_tickets', '101', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML006\", \"building\": \"Block A\", \"subject\": \"Kitchen cupboard hinge is loose\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 14:25:00'),
(1128, 295, 'Ticket Submitted', 'maintenance_tickets', '102', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML007\", \"building\": \"Block A\", \"subject\": \"Ants inside kitchen cabinet\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 14:42:00'),
(1129, 303, 'Ticket Submitted', 'maintenance_tickets', '103', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML008\", \"building\": \"Block B\", \"subject\": \"Lift door closes too slowly\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 14:59:00'),
(1130, 306, 'Ticket Submitted', 'maintenance_tickets', '104', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML009\", \"building\": \"Block B\", \"subject\": \"Smoke smell in the common corridor\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 17:00:00'),
(1131, 272, 'Ticket Submitted', 'maintenance_tickets', '105', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML010\", \"building\": \"Block B\", \"subject\": \"Strong gas smell near kitchen valve\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 17:17:00'),
(1132, 299, 'Ticket Submitted', 'maintenance_tickets', '106', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML011\", \"building\": \"Block B\", \"subject\": \"Water leaking beside an electrical switch\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 17:34:00');
INSERT INTO `audit_logs` (`audit_id`, `user_id`, `action_type`, `entity_type`, `entity_id`, `old_value`, `new_value`, `reason`, `ip_address`, `user_agent`, `created_at`) VALUES
(1133, 294, 'Ticket Submitted', 'maintenance_tickets', '107', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML012\", \"building\": \"Block B\", \"subject\": \"Ceiling material is falling\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 17:51:00'),
(1134, 282, 'Ticket Submitted', 'maintenance_tickets', '108', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML013\", \"building\": \"Block B\", \"subject\": \"Main bathroom pipe has burst\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 18:08:00'),
(1135, 278, 'Ticket Submitted', 'maintenance_tickets', '109', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML014\", \"building\": \"Block B\", \"subject\": \"Burning smell from air conditioner\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 18:25:00'),
(1136, 275, 'Ticket Submitted', 'maintenance_tickets', '110', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML015\", \"building\": \"Block B\", \"subject\": \"Emergency exit door will not unlock\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 18:42:00'),
(1137, 283, 'Ticket Submitted', 'maintenance_tickets', '118', NULL, '{\"ticket_number\": \"TCK-HF-260822-ML023\", \"building\": \"Block C\", \"subject\": \"Balcony door handle is loose\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 09:42:00'),
(1138, 308, 'Ticket Submitted', 'maintenance_tickets', '111', NULL, '{\"ticket_number\": \"TCK-HF-260823-ML016\", \"building\": \"Block C\", \"subject\": \"Chemical liquid spilled in stairwell\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-23 18:59:00'),
(1139, 286, 'Ticket Submitted', 'maintenance_tickets', '112', NULL, '{\"ticket_number\": \"TCK-HF-260822-ML017\", \"building\": \"Block C\", \"subject\": \"Lift door jerks while opening\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 08:00:00'),
(1140, 281, 'Ticket Submitted', 'maintenance_tickets', '113', NULL, '{\"ticket_number\": \"TCK-HF-260822-ML018\", \"building\": \"Block C\", \"subject\": \"Sewage is backing up through drain\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 08:17:00'),
(1141, 296, 'Ticket Submitted', 'maintenance_tickets', '114', NULL, '{\"ticket_number\": \"TCK-HF-260822-ML019\", \"building\": \"Block C\", \"subject\": \"Fire alarm panel shows a fault\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 08:34:00'),
(1142, 274, 'Ticket Submitted', 'maintenance_tickets', '115', NULL, '{\"ticket_number\": \"TCK-HF-260822-ML020\", \"building\": \"Block C\", \"subject\": \"Circuit breaker trips repeatedly\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 08:51:00'),
(1143, 305, 'Ticket Submitted', 'maintenance_tickets', '116', NULL, '{\"ticket_number\": \"TCK-HF-260822-ML021\", \"building\": \"Block C\", \"subject\": \"Wasp nest near balcony roof\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 09:08:00'),
(1144, 300, 'Ticket Submitted', 'maintenance_tickets', '117', NULL, '{\"ticket_number\": \"TCK-HF-260822-ML022\", \"building\": \"Block C\", \"subject\": \"Service water pump is noisy\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 09:25:00'),
(1145, 304, 'Ticket Submitted', 'maintenance_tickets', '119', NULL, '{\"ticket_number\": \"TCK-HF-260822-ML024\", \"building\": \"Block D\", \"subject\": \"ටොයිලට් සිස්ටර්න් එක දිගටම වතුර යවනවා\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-22 09:59:00'),
(1146, 279, 'Ticket Submitted', 'maintenance_tickets', '120', NULL, '{\"ticket_number\": \"TCK-HF-260821-ML025\", \"building\": \"Block D\", \"subject\": \"Two corridor lights are not working\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-21 09:00:00'),
(1147, 276, 'Ticket Submitted', 'maintenance_tickets', '121', NULL, '{\"ticket_number\": \"TCK-HF-260821-ML026\", \"building\": \"Block D\", \"subject\": \"Lobby intercom audio is unclear\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-21 09:17:00'),
(1148, 301, 'Ticket Submitted', 'maintenance_tickets', '122', NULL, '{\"ticket_number\": \"TCK-HF-260821-ML027\", \"building\": \"Block D\", \"subject\": \"Living room AC is not cooling\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-21 09:34:00'),
(1149, 284, 'Ticket Submitted', 'maintenance_tickets', '123', NULL, '{\"ticket_number\": \"TCK-HF-260821-ML028\", \"building\": \"Block D\", \"subject\": \"Balcony floor tile is lifting\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-21 09:51:00'),
(1150, 290, 'Ticket Submitted', 'maintenance_tickets', '124', NULL, '{\"ticket_number\": \"TCK-HF-260821-ML029\", \"building\": \"Block D\", \"subject\": \"Slippery liquid on stair landing\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-21 10:08:00'),
(1151, 309, 'Ticket Submitted', 'maintenance_tickets', '125', NULL, '{\"ticket_number\": \"TCK-HF-260821-ML030\", \"building\": \"Block D\", \"subject\": \"Balcony drain is blocked\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-21 10:25:00'),
(1152, 273, 'Ticket Submitted', 'maintenance_tickets', '126', NULL, '{\"ticket_number\": \"TCK-HF-260821-ML031\", \"building\": \"Block E\", \"subject\": \"Lift has unusual vibration\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-21 10:42:00'),
(1153, 287, 'Ticket Submitted', 'maintenance_tickets', '127', NULL, '{\"ticket_number\": \"TCK-HF-260818-ML032\", \"building\": \"Block E\", \"subject\": \"Gas regulator connection was loose\", \"status\": \"Submitted\", \"language_type\": \"English\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-18 10:29:00'),
(1154, 302, 'Ticket Submitted', 'maintenance_tickets', '128', NULL, '{\"ticket_number\": \"TCK-HF-260818-ML033\", \"building\": \"Block E\", \"subject\": \"Emergency light was not working\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-18 08:30:00'),
(1155, 298, 'Ticket Submitted', 'maintenance_tickets', '129', NULL, '{\"ticket_number\": \"TCK-HF-260818-ML034\", \"building\": \"Block E\", \"subject\": \"Main door was scraping the floor\", \"status\": \"Submitted\", \"language_type\": \"Singlish\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-18 08:47:00'),
(1156, 293, 'Ticket Submitted', 'maintenance_tickets', '130', NULL, '{\"ticket_number\": \"TCK-HF-260818-ML035\", \"building\": \"Block E\", \"subject\": \"Washing machine inlet hose was leaking\", \"status\": \"Submitted\", \"language_type\": \"Mixed\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-18 09:04:00'),
(1157, 289, 'Ticket Submitted', 'maintenance_tickets', '131', NULL, '{\"ticket_number\": \"TCK-HF-260818-ML036\", \"building\": \"Block E\", \"subject\": \"ලී දොර රාමුවේ වේයන්ගේ සලකුණු\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-18 09:21:00'),
(1158, 307, 'Ticket Submitted', 'maintenance_tickets', '132', NULL, '{\"ticket_number\": \"TCK-HF-260818-ML037\", \"building\": \"Block E\", \"subject\": \"Access card reader missed valid cards\", \"status\": \"Submitted\", \"language_type\": \"Sinhala\"}', 'Resident submitted a maintenance ticket through the HelaFixIt AI resident portal.', '127.0.0.1', 'HelaFixIt AI Web Portal', '2026-08-18 09:38:00'),
(1185, 285, 'AI Analysis', 'maintenance_tickets', '96', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 46.00, \"risk_level\": \"Medium\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 13:00:02'),
(1186, 277, 'AI Analysis', 'maintenance_tickets', '97', NULL, '{\"category\": \"Electrical\", \"priority\": \"Low\", \"risk_score\": 28.00, \"risk_level\": \"Low\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 13:17:02'),
(1187, 280, 'AI Analysis', 'maintenance_tickets', '98', NULL, '{\"category\": \"Air Conditioning\", \"priority\": \"Medium\", \"risk_score\": 42.00, \"risk_level\": \"Medium\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 13:34:02'),
(1188, 291, 'AI Analysis', 'maintenance_tickets', '99', NULL, '{\"category\": \"Security and Access\", \"priority\": \"Medium\", \"risk_score\": 51.00, \"risk_level\": \"Medium\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 13:51:02'),
(1189, 292, 'AI Analysis', 'maintenance_tickets', '100', NULL, '{\"category\": \"Drainage\", \"priority\": \"Medium\", \"risk_score\": 39.00, \"risk_level\": \"Medium\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 14:08:02'),
(1190, 288, 'AI Analysis', 'maintenance_tickets', '101', NULL, '{\"category\": \"Carpentry\", \"priority\": \"Low\", \"risk_score\": 22.00, \"risk_level\": \"Low\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 14:25:02'),
(1191, 295, 'AI Analysis', 'maintenance_tickets', '102', NULL, '{\"category\": \"Pest Control\", \"priority\": \"Low\", \"risk_score\": 25.00, \"risk_level\": \"Low\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 14:42:02'),
(1192, 303, 'AI Analysis', 'maintenance_tickets', '103', NULL, '{\"category\": \"Lift\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"manual_review_required\": 1, \"auto_assignment_required\": false, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 14:59:02'),
(1193, 306, 'AI Analysis', 'maintenance_tickets', '104', NULL, '{\"category\": \"Fire and Safety\", \"priority\": \"Emergency\", \"risk_score\": 96.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 17:00:02'),
(1194, 272, 'AI Analysis', 'maintenance_tickets', '105', NULL, '{\"category\": \"Gas\", \"priority\": \"Emergency\", \"risk_score\": 98.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 17:17:02'),
(1195, 299, 'AI Analysis', 'maintenance_tickets', '106', NULL, '{\"category\": \"Electrical\", \"priority\": \"Emergency\", \"risk_score\": 99.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 17:34:02'),
(1196, 294, 'AI Analysis', 'maintenance_tickets', '107', NULL, '{\"category\": \"Structural\", \"priority\": \"Emergency\", \"risk_score\": 93.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 17:51:02'),
(1197, 282, 'AI Analysis', 'maintenance_tickets', '108', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Emergency\", \"risk_score\": 95.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 18:08:02'),
(1198, 278, 'AI Analysis', 'maintenance_tickets', '109', NULL, '{\"category\": \"Air Conditioning\", \"priority\": \"Emergency\", \"risk_score\": 94.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 18:25:02'),
(1199, 275, 'AI Analysis', 'maintenance_tickets', '110', NULL, '{\"category\": \"Security and Access\", \"priority\": \"Emergency\", \"risk_score\": 91.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 18:42:02'),
(1200, 283, 'AI Analysis', 'maintenance_tickets', '118', NULL, '{\"category\": \"Carpentry\", \"priority\": \"Low\", \"risk_score\": 29.00, \"risk_level\": \"Low\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 09:42:02'),
(1201, 308, 'AI Analysis', 'maintenance_tickets', '111', NULL, '{\"category\": \"Cleaning\", \"priority\": \"Emergency\", \"risk_score\": 89.00, \"risk_level\": \"Critical\", \"manual_review_required\": 0, \"auto_assignment_required\": true, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-23 18:59:02'),
(1202, 286, 'AI Analysis', 'maintenance_tickets', '112', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 72.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 08:00:02'),
(1203, 281, 'AI Analysis', 'maintenance_tickets', '113', NULL, '{\"category\": \"Drainage\", \"priority\": \"High\", \"risk_score\": 78.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 08:17:02'),
(1204, 296, 'AI Analysis', 'maintenance_tickets', '114', NULL, '{\"category\": \"Fire and Safety\", \"priority\": \"High\", \"risk_score\": 74.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 08:34:02'),
(1205, 274, 'AI Analysis', 'maintenance_tickets', '115', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 68.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 08:51:02'),
(1206, 305, 'AI Analysis', 'maintenance_tickets', '116', NULL, '{\"category\": \"Pest Control\", \"priority\": \"Medium\", \"risk_score\": 54.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 09:08:02'),
(1207, 300, 'AI Analysis', 'maintenance_tickets', '117', NULL, '{\"category\": \"Other\", \"priority\": \"Medium\", \"risk_score\": 43.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 09:25:02'),
(1208, 304, 'AI Analysis', 'maintenance_tickets', '119', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 38.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-22 09:59:02'),
(1209, 279, 'AI Analysis', 'maintenance_tickets', '120', NULL, '{\"category\": \"Electrical\", \"priority\": \"Medium\", \"risk_score\": 41.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-21 09:00:02'),
(1210, 276, 'AI Analysis', 'maintenance_tickets', '121', NULL, '{\"category\": \"Security and Access\", \"priority\": \"Medium\", \"risk_score\": 37.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-21 09:17:02'),
(1211, 301, 'AI Analysis', 'maintenance_tickets', '122', NULL, '{\"category\": \"Air Conditioning\", \"priority\": \"Medium\", \"risk_score\": 45.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-21 09:34:02'),
(1212, 284, 'AI Analysis', 'maintenance_tickets', '123', NULL, '{\"category\": \"Structural\", \"priority\": \"High\", \"risk_score\": 63.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-21 09:51:02'),
(1213, 290, 'AI Analysis', 'maintenance_tickets', '124', NULL, '{\"category\": \"Cleaning\", \"priority\": \"Medium\", \"risk_score\": 35.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-21 10:08:02'),
(1214, 309, 'AI Analysis', 'maintenance_tickets', '125', NULL, '{\"category\": \"Drainage\", \"priority\": \"Medium\", \"risk_score\": 49.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-21 10:25:02'),
(1215, 273, 'AI Analysis', 'maintenance_tickets', '126', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 70.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-21 10:42:02'),
(1216, 287, 'AI Analysis', 'maintenance_tickets', '127', NULL, '{\"category\": \"Gas\", \"priority\": \"High\", \"risk_score\": 66.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"English\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-18 10:29:02'),
(1217, 302, 'AI Analysis', 'maintenance_tickets', '128', NULL, '{\"category\": \"Fire and Safety\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-18 08:30:02'),
(1218, 298, 'AI Analysis', 'maintenance_tickets', '129', NULL, '{\"category\": \"Carpentry\", \"priority\": \"Low\", \"risk_score\": 26.00, \"risk_level\": \"Low\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Singlish\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-18 08:47:02'),
(1219, 293, 'AI Analysis', 'maintenance_tickets', '130', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 44.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-18 09:04:02'),
(1220, 289, 'AI Analysis', 'maintenance_tickets', '131', NULL, '{\"category\": \"Pest Control\", \"priority\": \"Medium\", \"risk_score\": 52.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-18 09:21:02'),
(1221, 307, 'AI Analysis', 'maintenance_tickets', '132', NULL, '{\"category\": \"Security and Access\", \"priority\": \"Medium\", \"risk_score\": 47.00, \"risk_level\": \"Medium\", \"manual_review_required\": 0, \"auto_assignment_required\": false, \"language_type\": \"Sinhala\"}', 'Local HelaFixIt AI ticket decision process completed using the active model and risk rules.', '127.0.0.1', 'HelaFixIt AI Service', '2026-08-18 09:38:02'),
(1248, 336, 'Ticket Review', 'maintenance_tickets', '118', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 8, \"priority\": \"Low\", \"risk_score\": 29.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 10:06:00'),
(1249, 336, 'Ticket Review', 'maintenance_tickets', '112', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 3, \"priority\": \"High\", \"risk_score\": 72.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 08:24:00'),
(1250, 336, 'Ticket Review', 'maintenance_tickets', '113', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 5, \"priority\": \"High\", \"risk_score\": 78.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 08:41:00'),
(1251, 336, 'Ticket Review', 'maintenance_tickets', '114', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 10, \"priority\": \"High\", \"risk_score\": 74.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 08:58:00'),
(1252, 336, 'Ticket Review', 'maintenance_tickets', '115', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 1, \"priority\": \"High\", \"risk_score\": 68.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 09:15:00'),
(1253, 336, 'Ticket Review', 'maintenance_tickets', '116', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 7, \"priority\": \"Medium\", \"risk_score\": 54.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 09:32:00'),
(1254, 336, 'Ticket Review', 'maintenance_tickets', '117', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 9, \"priority\": \"Medium\", \"risk_score\": 43.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 09:49:00'),
(1255, 337, 'Ticket Review', 'maintenance_tickets', '119', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 2, \"priority\": \"Medium\", \"risk_score\": 38.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 10:23:00'),
(1256, 337, 'Ticket Review', 'maintenance_tickets', '120', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 1, \"priority\": \"Medium\", \"risk_score\": 41.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:24:00'),
(1257, 337, 'Ticket Review', 'maintenance_tickets', '121', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 13, \"priority\": \"Medium\", \"risk_score\": 37.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:41:00'),
(1258, 337, 'Ticket Review', 'maintenance_tickets', '122', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 4, \"priority\": \"Medium\", \"risk_score\": 45.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:58:00'),
(1259, 337, 'Ticket Review', 'maintenance_tickets', '123', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 12, \"priority\": \"High\", \"risk_score\": 63.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 10:15:00'),
(1260, 337, 'Ticket Review', 'maintenance_tickets', '124', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 6, \"priority\": \"Medium\", \"risk_score\": 35.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 10:32:00'),
(1261, 337, 'Ticket Review', 'maintenance_tickets', '125', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 5, \"priority\": \"Medium\", \"risk_score\": 49.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 10:49:00'),
(1262, 338, 'Ticket Review', 'maintenance_tickets', '126', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 3, \"priority\": \"High\", \"risk_score\": 70.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 11:06:00'),
(1263, 338, 'Ticket Review', 'maintenance_tickets', '127', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 11, \"priority\": \"High\", \"risk_score\": 66.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 10:49:00'),
(1264, 338, 'Ticket Review', 'maintenance_tickets', '128', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 10, \"priority\": \"High\", \"risk_score\": 64.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 08:50:00'),
(1265, 338, 'Ticket Review', 'maintenance_tickets', '129', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 8, \"priority\": \"Low\", \"risk_score\": 26.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:07:00'),
(1266, 338, 'Ticket Review', 'maintenance_tickets', '130', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 2, \"priority\": \"Medium\", \"risk_score\": 44.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:24:00'),
(1267, 338, 'Ticket Review', 'maintenance_tickets', '131', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 7, \"priority\": \"Medium\", \"risk_score\": 52.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:41:00'),
(1268, 338, 'Ticket Review', 'maintenance_tickets', '132', '{\"status\": \"Awaiting Review\"}', '{\"category_id\": 13, \"priority\": \"Medium\", \"risk_score\": 47.00, \"review\": \"Approved\"}', 'Apartment admin reviewed and accepted the AI decision before technician assignment.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:58:00'),
(1279, 336, 'Technician Assigned', 'maintenance_tickets', '118', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 182, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 10:20:00'),
(1280, 336, 'Technician Assigned', 'maintenance_tickets', '112', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 158, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 08:38:00'),
(1281, 336, 'Technician Assigned', 'maintenance_tickets', '113', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 171, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 08:55:00'),
(1282, 336, 'Technician Assigned', 'maintenance_tickets', '114', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 189, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 09:12:00'),
(1283, 336, 'Technician Assigned', 'maintenance_tickets', '115', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 152, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 09:29:00'),
(1284, 336, 'Technician Assigned', 'maintenance_tickets', '116', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 180, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 09:46:00'),
(1285, 336, 'Technician Assigned', 'maintenance_tickets', '117', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 188, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 10:03:00'),
(1286, 337, 'Technician Assigned', 'maintenance_tickets', '119', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 210, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-22 10:37:00'),
(1287, 337, 'Technician Assigned', 'maintenance_tickets', '120', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 204, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:38:00'),
(1288, 337, 'Technician Assigned', 'maintenance_tickets', '121', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 168, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:55:00'),
(1289, 337, 'Technician Assigned', 'maintenance_tickets', '122', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 214, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 10:12:00'),
(1290, 337, 'Technician Assigned', 'maintenance_tickets', '123', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 166, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 10:29:00'),
(1291, 337, 'Technician Assigned', 'maintenance_tickets', '124', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 216, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 10:46:00'),
(1292, 337, 'Technician Assigned', 'maintenance_tickets', '125', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 215, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 11:03:00'),
(1293, 338, 'Technician Assigned', 'maintenance_tickets', '126', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 175, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 11:20:00'),
(1294, 338, 'Technician Assigned', 'maintenance_tickets', '127', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 202, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 11:01:00'),
(1295, 338, 'Technician Assigned', 'maintenance_tickets', '128', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 197, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:02:00'),
(1296, 338, 'Technician Assigned', 'maintenance_tickets', '129', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 191, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:19:00'),
(1297, 338, 'Technician Assigned', 'maintenance_tickets', '130', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 172, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:36:00'),
(1298, 338, 'Technician Assigned', 'maintenance_tickets', '131', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 190, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 09:53:00'),
(1299, 338, 'Technician Assigned', 'maintenance_tickets', '132', '{\"status\": \"Awaiting Review\"}', '{\"status\": \"Assigned\", \"technician_id\": 212, \"assignment_method\": \"Manual\"}', 'Apartment admin assigned a suitable technician from the same building and matching maintenance category.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-18 10:10:00'),
(1310, 402, 'Job Accepted', 'maintenance_tickets', '120', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 09:47:00'),
(1311, 366, 'Job Accepted', 'maintenance_tickets', '121', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 10:04:00'),
(1312, 412, 'Job Accepted', 'maintenance_tickets', '122', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 10:21:00'),
(1313, 364, 'Job Accepted', 'maintenance_tickets', '123', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 10:38:00'),
(1314, 414, 'Job Accepted', 'maintenance_tickets', '124', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 10:55:00'),
(1315, 413, 'Job Accepted', 'maintenance_tickets', '125', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 11:12:00'),
(1316, 373, 'Job Accepted', 'maintenance_tickets', '126', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 11:29:00'),
(1317, 400, 'Job Accepted', 'maintenance_tickets', '127', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 11:12:00'),
(1318, 395, 'Job Accepted', 'maintenance_tickets', '128', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 09:13:00'),
(1319, 389, 'Job Accepted', 'maintenance_tickets', '129', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 09:30:00'),
(1320, 370, 'Job Accepted', 'maintenance_tickets', '130', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 09:47:00'),
(1321, 388, 'Job Accepted', 'maintenance_tickets', '131', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 10:04:00'),
(1322, 410, 'Job Accepted', 'maintenance_tickets', '132', '{\"status\": \"Assigned\"}', '{\"status\": \"Accepted\"}', 'Technician accepted the assigned maintenance job.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 10:21:00'),
(1325, 402, 'Job Started', 'maintenance_tickets', '120', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 09:59:00'),
(1326, 366, 'Job Started', 'maintenance_tickets', '121', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 10:16:00'),
(1327, 412, 'Job Started', 'maintenance_tickets', '122', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 10:33:00'),
(1328, 364, 'Job Started', 'maintenance_tickets', '123', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 10:50:00'),
(1329, 414, 'Job Started', 'maintenance_tickets', '124', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 11:07:00'),
(1330, 413, 'Job Started', 'maintenance_tickets', '125', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 11:24:00'),
(1331, 373, 'Job Started', 'maintenance_tickets', '126', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-21 11:41:00'),
(1332, 400, 'Job Started', 'maintenance_tickets', '127', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 11:24:00'),
(1333, 395, 'Job Started', 'maintenance_tickets', '128', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 09:25:00'),
(1334, 389, 'Job Started', 'maintenance_tickets', '129', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 09:42:00'),
(1335, 370, 'Job Started', 'maintenance_tickets', '130', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 09:59:00'),
(1336, 388, 'Job Started', 'maintenance_tickets', '131', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 10:16:00'),
(1337, 410, 'Job Started', 'maintenance_tickets', '132', '{\"status\": \"Accepted\"}', '{\"status\": \"In Progress\"}', 'Technician started the maintenance work and updated the job status.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 10:33:00'),
(1340, 400, 'Job Resolved', 'maintenance_tickets', '127', '{\"status\": \"In Progress\"}', '{\"status\": \"Resolved\", \"completion_note\": \"Technician tightened the regulator connection, replaced the worn sealing washer and completed a leak test with no leak detected.\"}', 'Technician completed the maintenance work and recorded the resolution in the system.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 12:44:00'),
(1341, 395, 'Job Resolved', 'maintenance_tickets', '128', '{\"status\": \"In Progress\"}', '{\"status\": \"Resolved\", \"completion_note\": \"Emergency light battery and lamp module were replaced. The unit passed the power failure test.\"}', 'Technician completed the maintenance work and recorded the resolution in the system.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 10:15:00'),
(1342, 389, 'Job Resolved', 'maintenance_tickets', '129', '{\"status\": \"In Progress\"}', '{\"status\": \"Resolved\", \"completion_note\": \"Door hinges were aligned and tightened, and the lower edge was adjusted so the door opens and closes without scraping.\"}', 'Technician completed the maintenance work and recorded the resolution in the system.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 10:47:00'),
(1343, 370, 'Job Resolved', 'maintenance_tickets', '130', '{\"status\": \"In Progress\"}', '{\"status\": \"Resolved\", \"completion_note\": \"The damaged inlet hose washer was replaced, the coupling was tightened and the water connection was tested without leakage.\"}', 'Technician completed the maintenance work and recorded the resolution in the system.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 11:19:00'),
(1344, 388, 'Job Resolved', 'maintenance_tickets', '131', '{\"status\": \"In Progress\"}', '{\"status\": \"Resolved\", \"completion_note\": \"Affected timber was treated for termites and the surrounding wooden frame was inspected. A follow-up inspection was scheduled.\"}', 'Technician completed the maintenance work and recorded the resolution in the system.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 11:06:00');
INSERT INTO `audit_logs` (`audit_id`, `user_id`, `action_type`, `entity_type`, `entity_id`, `old_value`, `new_value`, `reason`, `ip_address`, `user_agent`, `created_at`) VALUES
(1345, 410, 'Job Resolved', 'maintenance_tickets', '132', '{\"status\": \"In Progress\"}', '{\"status\": \"Resolved\", \"completion_note\": \"The card reader was cleaned and reconfigured. Multiple resident access cards were tested successfully after the repair.\"}', 'Technician completed the maintenance work and recorded the resolution in the system.', '127.0.0.1', 'HelaFixIt AI Technician Portal', '2026-08-18 11:38:00'),
(1347, 339, 'Emergency Assignment Pending', 'maintenance_tickets', '104', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 96.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 17:00:03'),
(1348, 339, 'Emergency Assignment Pending', 'maintenance_tickets', '105', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 98.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 17:17:03'),
(1349, 339, 'Emergency Assignment Pending', 'maintenance_tickets', '106', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 99.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 17:34:03'),
(1350, 339, 'Emergency Assignment Pending', 'maintenance_tickets', '107', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 93.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 17:51:03'),
(1351, 339, 'Emergency Assignment Pending', 'maintenance_tickets', '108', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 95.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 18:08:03'),
(1352, 339, 'Emergency Assignment Pending', 'maintenance_tickets', '109', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 94.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 18:25:03'),
(1353, 339, 'Emergency Assignment Pending', 'maintenance_tickets', '110', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 91.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 18:42:03'),
(1354, 336, 'Emergency Assignment Pending', 'maintenance_tickets', '111', '{\"status\": \"Analysing\"}', '{\"status\": \"Urgent Unassigned\", \"priority\": \"Emergency\", \"risk_score\": 89.00}', 'The emergency ticket required immediate assignment, but no eligible matching technician was available at the historical event time. Admin attention was requested.', '127.0.0.1', 'HelaFixIt AI Assignment Service', '2026-08-23 18:59:03'),
(1362, 15, 'Maintenance Ticket Records Created', 'ticket_batch', 'TICKETS-AUG2026-ML37', NULL, '{\"total_tickets\": 37, \"awaiting_admin_review\": 8, \"urgent_unassigned\": 8, \"assigned_jobs\": 8, \"in_progress_jobs\": 7, \"completed_jobs\": 6, \"buildings\": 5, \"period_start\": \"2026-08-18\", \"period_end\": \"2026-08-23\", \"english_tickets\": 7, \"sinhala_tickets\": 12, \"singlish_tickets\": 9, \"mixed_tickets\": 9}', 'Thirty-seven multilingual maintenance ticket records covering English, Sinhala, Singlish and mixed-language descriptions were created during the previous week across all five HelaFixIt AI buildings.', '127.0.0.1', 'HelaFixIt AI System Admin Console', '2026-08-23 23:10:00'),
(1363, 300, 'Ticket Submitted', 'maintenance_tickets', '133', NULL, '{\"ticket_number\": \"TCK-260826-140CCD38\", \"subject\": \"නාන කාමරයේ වතුර බටය කැඩී වතුර ගලා යනවා\", \"language_type\": \"Mixed\"}', 'Resident submitted a live maintenance ticket through the Flask application.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', '2026-08-26 18:44:33'),
(1364, 300, 'AI Analysis', 'maintenance_tickets', '133', NULL, '{\"category\": \"Plumbing\", \"priority\": \"High\", \"risk_score\": 53.2, \"risk_level\": \"Medium\", \"duplicate\": null, \"recommended_technician\": 171, \"auto_assignment\": false, \"language_type\": \"Mixed\"}', 'Local HelaFixIt AI ticket decision process.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', '2026-08-26 18:44:35'),
(1365, 336, 'Ticket Review', 'maintenance_tickets', '133', '{\"category_id\": 2, \"priority\": \"High\"}', '{\"category_id\": 2, \"priority\": \"High\"}', 'Apartment admin reviewed the live ticket.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', '2026-08-26 18:57:25'),
(1366, 336, 'Technician Assigned', 'maintenance_tickets', '133', NULL, '{\"technician_id\": 171, \"method\": \"Manual\"}', 'Manual assignment by apartment admin.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', '2026-08-26 18:57:50'),
(1367, 369, 'Job Resolved', 'maintenance_tickets', '133', NULL, '{\"status\": \"Resolved\"}', 'Completed', NULL, NULL, '2026-08-26 19:02:08'),
(1370, 15, 'User Created', 'users', '484', NULL, '{\"full_name\": \"Tharushi Senanayake\", \"email\": \"tharushi.senanayake@proton.me\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 9, \"unit\": \"A-903\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:00:00'),
(1371, 15, 'User Created', 'users', '485', NULL, '{\"full_name\": \"Pasindu Madushanka\", \"email\": \"pasindu.madushanka@msn.com\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 10, \"unit\": \"A-1004\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 09:37:00'),
(1372, 15, 'User Created', 'users', '486', NULL, '{\"full_name\": \"Oshadi Wijesinghe\", \"email\": \"oshadi.wijesinghe@gmail.com\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 12, \"unit\": \"A-1202\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 10:14:00'),
(1373, 15, 'User Created', 'users', '487', NULL, '{\"full_name\": \"Sahan Jayalath\", \"email\": \"sahan.jayalath@outlook.com\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 14, \"unit\": \"A-1405\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 10:51:00'),
(1374, 15, 'User Created', 'users', '488', NULL, '{\"full_name\": \"Navodya Bandara\", \"email\": \"navodya.bandara@hotmail.com\", \"role\": \"Resident\", \"building\": \"Block A\", \"floor\": 15, \"unit\": \"A-1506\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 11:28:00'),
(1375, 15, 'User Created', 'users', '489', NULL, '{\"full_name\": \"Kaveesha Rathnayake\", \"email\": \"kaveesha.rathnayake@yahoo.com\", \"role\": \"Resident\", \"building\": \"Block B\", \"floor\": 9, \"unit\": \"B-902\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 12:05:00'),
(1376, 15, 'User Created', 'users', '490', NULL, '{\"full_name\": \"Thisara Abeysekara\", \"email\": \"thisara.abeysekara@icloud.com\", \"role\": \"Resident\", \"building\": \"Block B\", \"floor\": 10, \"unit\": \"B-1003\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 12:42:00'),
(1377, 15, 'User Created', 'users', '491', NULL, '{\"full_name\": \"Chathuni Gamage\", \"email\": \"chathuni.gamage@live.com\", \"role\": \"Resident\", \"building\": \"Block B\", \"floor\": 12, \"unit\": \"B-1204\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 13:19:00'),
(1378, 15, 'User Created', 'users', '492', NULL, '{\"full_name\": \"Duleeka Ranasinghe\", \"email\": \"duleeka.ranasinghe@proton.me\", \"role\": \"Resident\", \"building\": \"Block B\", \"floor\": 14, \"unit\": \"B-1402\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 13:56:00'),
(1379, 15, 'User Created', 'users', '493', NULL, '{\"full_name\": \"Sachin Fernando\", \"email\": \"sachin.fernando@msn.com\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 9, \"unit\": \"C-903\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 14:33:00'),
(1380, 15, 'User Created', 'users', '494', NULL, '{\"full_name\": \"Nimesha Weerasinghe\", \"email\": \"nimesha.weerasinghe@gmail.com\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 10, \"unit\": \"C-1002\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 15:10:00'),
(1381, 15, 'User Created', 'users', '495', NULL, '{\"full_name\": \"Lasith Perera\", \"email\": \"lasith.perera@outlook.com\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 12, \"unit\": \"C-1203\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 15:47:00'),
(1382, 15, 'User Created', 'users', '496', NULL, '{\"full_name\": \"Piumi Gunasekara\", \"email\": \"piumi.gunasekara@hotmail.com\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 14, \"unit\": \"C-1404\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 16:24:00'),
(1383, 15, 'User Created', 'users', '497', NULL, '{\"full_name\": \"Ravindu Pathirana\", \"email\": \"ravindu.pathirana@yahoo.com\", \"role\": \"Resident\", \"building\": \"Block C\", \"floor\": 16, \"unit\": \"C-1602\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 17:01:00'),
(1384, 15, 'User Created', 'users', '498', NULL, '{\"full_name\": \"Himashi Wickramanayake\", \"email\": \"himashi.wickramanayake@icloud.com\", \"role\": \"Resident\", \"building\": \"Block D\", \"floor\": 8, \"unit\": \"D-802\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 17:38:00'),
(1385, 15, 'User Created', 'users', '499', NULL, '{\"full_name\": \"Kavisha Maduranga\", \"email\": \"kavisha.maduranga@live.com\", \"role\": \"Resident\", \"building\": \"Block D\", \"floor\": 9, \"unit\": \"D-903\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 18:15:00'),
(1386, 15, 'User Created', 'users', '500', NULL, '{\"full_name\": \"Senuri De Alwis\", \"email\": \"senuri.dealwis@proton.me\", \"role\": \"Resident\", \"building\": \"Block D\", \"floor\": 10, \"unit\": \"D-1004\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 18:52:00'),
(1387, 15, 'User Created', 'users', '501', NULL, '{\"full_name\": \"Ashen Rodrigo\", \"email\": \"ashen.rodrigo@msn.com\", \"role\": \"Resident\", \"building\": \"Block D\", \"floor\": 6, \"unit\": \"D-602\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 19:29:00'),
(1388, 15, 'User Created', 'users', '502', NULL, '{\"full_name\": \"Thilini Edirisinghe\", \"email\": \"thilini.edirisinghe@gmail.com\", \"role\": \"Resident\", \"building\": \"Block E\", \"floor\": 8, \"unit\": \"E-802\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 20:06:00'),
(1389, 15, 'User Created', 'users', '503', NULL, '{\"full_name\": \"Malith Peiris\", \"email\": \"malith.peiris@outlook.com\", \"role\": \"Resident\", \"building\": \"Block E\", \"floor\": 9, \"unit\": \"E-903\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 20:43:00'),
(1390, 15, 'User Created', 'users', '504', NULL, '{\"full_name\": \"Vihanga Samarawickrama\", \"email\": \"vihanga.samarawickrama@hotmail.com\", \"role\": \"Resident\", \"building\": \"Block E\", \"floor\": 10, \"unit\": \"E-1004\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 21:20:00'),
(1391, 15, 'User Created', 'users', '505', NULL, '{\"full_name\": \"Dinuka Nawaratne\", \"email\": \"dinuka.nawaratne@yahoo.com\", \"role\": \"Resident\", \"building\": \"Block E\", \"floor\": 11, \"unit\": \"E-1102\"}', 'Synthetic resident account created for controlled system testing and demonstration.', '127.0.0.1', 'HelaFixIt AI Admin Console', '2026-08-21 21:57:00'),
(1396, 277, 'Ticket Submitted', 'maintenance_tickets', '134', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R092\", \"subject\": \"Lift making grinding noise at this floor\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 08:15:00'),
(1397, 280, 'Ticket Submitted', 'maintenance_tickets', '135', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R095\", \"subject\": \"Lift making grinding noise at this floor - repeated report\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 09:28:00'),
(1398, 285, 'Ticket Submitted', 'maintenance_tickets', '136', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R100\", \"subject\": \"Water leak in common corridor\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 10:41:00'),
(1399, 288, 'Ticket Submitted', 'maintenance_tickets', '137', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R103\", \"subject\": \"Water leak in common corridor - repeated report\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 11:54:00'),
(1400, 291, 'Ticket Submitted', 'maintenance_tickets', '138', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R106\", \"subject\": \"පොදු කොරිඩෝරයේ ලයිට් දිලිසෙනවා\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 13:07:00'),
(1401, 292, 'Ticket Submitted', 'maintenance_tickets', '139', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R107\", \"subject\": \"Common corridor lights flickering - repeated report\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 14:20:00'),
(1402, 295, 'Ticket Submitted', 'maintenance_tickets', '140', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R110\", \"subject\": \"Bedroom door not closing properly\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 15:33:00'),
(1403, 297, 'Ticket Submitted', 'maintenance_tickets', '141', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R112\", \"subject\": \"ප්‍රධාන දොරේ අගුල හරියට වැටෙන්නේ නැහැ\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 16:46:00'),
(1404, 484, 'Ticket Submitted', 'maintenance_tickets', '142', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R125\", \"subject\": \"Bathroom tap eka leak wenawa\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 17:59:00'),
(1405, 485, 'Ticket Submitted', 'maintenance_tickets', '143', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R126\", \"subject\": \"Drain water flowing slowly\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 19:12:00'),
(1406, 486, 'Ticket Submitted', 'maintenance_tickets', '144', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R127\", \"subject\": \"Pest activity in kitchen\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 20:25:00'),
(1407, 487, 'Ticket Submitted', 'maintenance_tickets', '145', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R128\", \"subject\": \"Loose fitting needs repair\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 21:38:00'),
(1408, 488, 'Ticket Submitted', 'maintenance_tickets', '146', NULL, '{\"ticket_number\": \"TCK-HF-260827-A-R129\", \"subject\": \"Entrance door lock eka hariyata lock wenne naha\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 22:51:00'),
(1409, 272, 'Ticket Submitted', 'maintenance_tickets', '147', NULL, '{\"ticket_number\": \"TCK-HF-260827-B-R087\", \"subject\": \"Lift making grinding noise at this floor\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 00:04:00'),
(1410, 275, 'Ticket Submitted', 'maintenance_tickets', '148', NULL, '{\"ticket_number\": \"TCK-HF-260827-B-R090\", \"subject\": \"Lift making grinding noise at this floor - repeated report\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 01:17:00'),
(1411, 278, 'Ticket Submitted', 'maintenance_tickets', '149', NULL, '{\"ticket_number\": \"TCK-HF-260827-B-R093\", \"subject\": \"Water leak in common corridor\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 02:30:00'),
(1412, 282, 'Ticket Submitted', 'maintenance_tickets', '150', NULL, '{\"ticket_number\": \"TCK-HF-260827-B-R097\", \"subject\": \"Water leak in common corridor - repeated report\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 03:43:00'),
(1413, 294, 'Ticket Submitted', 'maintenance_tickets', '151', NULL, '{\"ticket_number\": \"TCK-HF-260827-B-R109\", \"subject\": \"පොදු කොරිඩෝරයේ ලයිට් දිලිසෙනවා\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 04:56:00'),
(1414, 299, 'Ticket Submitted', 'maintenance_tickets', '152', NULL, '{\"ticket_number\": \"TCK-HF-260827-B-R114\", \"subject\": \"Common corridor lights flickering - repeated report\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 06:09:00'),
(1415, 303, 'Ticket Submitted', 'maintenance_tickets', '153', NULL, '{\"ticket_number\": \"TCK-HF-260827-B-R118\", \"subject\": \"Kitchen eke cockroach la penenawa\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 07:22:00'),
(1416, 306, 'Ticket Submitted', 'maintenance_tickets', '154', NULL, '{\"ticket_number\": \"TCK-HF-260827-B-R121\", \"subject\": \"Door lock not securing properly\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 08:35:00'),
(1417, 489, 'Ticket Submitted', 'maintenance_tickets', '155', NULL, '{\"ticket_number\": \"TCK-HF-260827-B-R130\", \"subject\": \"Small ceiling crack noticed\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 09:48:00'),
(1418, 490, 'Ticket Submitted', 'maintenance_tickets', '156', NULL, '{\"ticket_number\": \"TCK-HF-260827-B-R131\", \"subject\": \"Lift eka nawathinawata unusual saddayak enawa\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 11:01:00'),
(1419, 491, 'Ticket Submitted', 'maintenance_tickets', '157', NULL, '{\"ticket_number\": \"TCK-HF-260827-B-R132\", \"subject\": \"Bathroom tap leaking\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 12:14:00'),
(1420, 492, 'Ticket Submitted', 'maintenance_tickets', '158', NULL, '{\"ticket_number\": \"TCK-HF-260827-B-R133\", \"subject\": \"Drain water flowing slowly\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 13:27:00'),
(1421, 274, 'Ticket Submitted', 'maintenance_tickets', '159', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R089\", \"subject\": \"ලිෆ්ට් එක නවත්වන විට ගැටෙන වගේ ශබ්දයක් එනවා\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 14:40:00'),
(1422, 281, 'Ticket Submitted', 'maintenance_tickets', '160', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R096\", \"subject\": \"Lift making grinding noise at this floor - repeated report\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 15:53:00'),
(1423, 283, 'Ticket Submitted', 'maintenance_tickets', '161', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R098\", \"subject\": \"Water leak in common corridor\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 17:06:00'),
(1424, 286, 'Ticket Submitted', 'maintenance_tickets', '162', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R101\", \"subject\": \"Water leak in common corridor - repeated report\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 18:19:00'),
(1425, 296, 'Ticket Submitted', 'maintenance_tickets', '163', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R111\", \"subject\": \"Common corridor lights flickering\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 19:32:00'),
(1426, 300, 'Ticket Submitted', 'maintenance_tickets', '164', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R115\", \"subject\": \"Common corridor lights flickering - repeated report\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 20:45:00'),
(1427, 305, 'Ticket Submitted', 'maintenance_tickets', '165', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R120\", \"subject\": \"Small ceiling crack noticed\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 21:58:00'),
(1428, 308, 'Ticket Submitted', 'maintenance_tickets', '166', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R123\", \"subject\": \"නාන කාමරයේ ටැප් එකෙන් වතුර කාන්දු වෙනවා\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 23:11:00'),
(1429, 493, 'Ticket Submitted', 'maintenance_tickets', '167', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R134\", \"subject\": \"AC eka cool karanne naha\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 00:24:00'),
(1430, 494, 'Ticket Submitted', 'maintenance_tickets', '168', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R135\", \"subject\": \"Common area needs cleaning\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 01:37:00'),
(1431, 495, 'Ticket Submitted', 'maintenance_tickets', '169', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R136\", \"subject\": \"Bedroom door not closing properly\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 02:50:00'),
(1432, 496, 'Ticket Submitted', 'maintenance_tickets', '170', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R137\", \"subject\": \"Ceiling eke podi crack ekak penenawa\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 04:03:00'),
(1433, 497, 'Ticket Submitted', 'maintenance_tickets', '171', NULL, '{\"ticket_number\": \"TCK-HF-260827-C-R138\", \"subject\": \"Lift stopping with unusual noise\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 05:16:00'),
(1434, 276, 'Ticket Submitted', 'maintenance_tickets', '172', NULL, '{\"ticket_number\": \"TCK-HF-260827-D-R091\", \"subject\": \"Lift making grinding noise at this floor\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 06:29:00'),
(1435, 279, 'Ticket Submitted', 'maintenance_tickets', '173', NULL, '{\"ticket_number\": \"TCK-HF-260827-D-R094\", \"subject\": \"Lift making grinding noise at this floor - repeated report\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 07:42:00'),
(1436, 284, 'Ticket Submitted', 'maintenance_tickets', '174', NULL, '{\"ticket_number\": \"TCK-HF-260827-D-R099\", \"subject\": \"පොදු කොරිඩෝරයේ වතුර කාන්දුවක්\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 08:55:00'),
(1437, 290, 'Ticket Submitted', 'maintenance_tickets', '175', NULL, '{\"ticket_number\": \"TCK-HF-260827-D-R105\", \"subject\": \"Water leak in common corridor - repeated report\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 10:08:00'),
(1438, 301, 'Ticket Submitted', 'maintenance_tickets', '176', NULL, '{\"ticket_number\": \"TCK-HF-260827-D-R116\", \"subject\": \"Common corridor lights flickering\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 11:21:00'),
(1439, 304, 'Ticket Submitted', 'maintenance_tickets', '177', NULL, '{\"ticket_number\": \"TCK-HF-260827-D-R119\", \"subject\": \"Common corridor lights flicker wenawa - duplicate report\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 12:34:00'),
(1440, 309, 'Ticket Submitted', 'maintenance_tickets', '178', NULL, '{\"ticket_number\": \"TCK-HF-260827-D-R124\", \"subject\": \"Drain water flowing slowly\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 13:47:00'),
(1441, 498, 'Ticket Submitted', 'maintenance_tickets', '179', NULL, '{\"ticket_number\": \"TCK-HF-260827-D-R139\", \"subject\": \"Small ceiling crack noticed\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 15:00:00'),
(1442, 499, 'Ticket Submitted', 'maintenance_tickets', '180', NULL, '{\"ticket_number\": \"TCK-HF-260827-D-R140\", \"subject\": \"Lift eka nawathinawata saddayak enawa\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 16:13:00'),
(1443, 500, 'Ticket Submitted', 'maintenance_tickets', '181', NULL, '{\"ticket_number\": \"TCK-HF-260827-D-R141\", \"subject\": \"Bathroom tap leaking\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 17:26:00'),
(1444, 501, 'Ticket Submitted', 'maintenance_tickets', '182', NULL, '{\"ticket_number\": \"TCK-HF-260827-D-R142\", \"subject\": \"Drain water flowing slowly\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 18:39:00'),
(1445, 273, 'Ticket Submitted', 'maintenance_tickets', '183', NULL, '{\"ticket_number\": \"TCK-HF-260827-E-R088\", \"subject\": \"Lift making grinding noise at this floor\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 19:52:00'),
(1446, 287, 'Ticket Submitted', 'maintenance_tickets', '184', NULL, '{\"ticket_number\": \"TCK-HF-260827-E-R102\", \"subject\": \"මේ මහලේ ලිෆ්ට් එකෙන් ගැටෙන වගේ ශබ්දයක් - නැවත පැමිණිල්ලක්\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 21:05:00'),
(1447, 289, 'Ticket Submitted', 'maintenance_tickets', '185', NULL, '{\"ticket_number\": \"TCK-HF-260827-E-R104\", \"subject\": \"Common corridor eke water leak ekak\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 22:18:00'),
(1448, 293, 'Ticket Submitted', 'maintenance_tickets', '186', NULL, '{\"ticket_number\": \"TCK-HF-260827-E-R108\", \"subject\": \"Water leak in common corridor - repeated report\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 23:31:00'),
(1449, 298, 'Ticket Submitted', 'maintenance_tickets', '187', NULL, '{\"ticket_number\": \"TCK-HF-260827-E-R113\", \"subject\": \"Common corridor lights flickering\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 00:44:00'),
(1450, 302, 'Ticket Submitted', 'maintenance_tickets', '188', NULL, '{\"ticket_number\": \"TCK-HF-260827-E-R117\", \"subject\": \"Common corridor lights flickering - repeated report\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 01:57:00'),
(1451, 307, 'Ticket Submitted', 'maintenance_tickets', '189', NULL, '{\"ticket_number\": \"TCK-HF-260827-E-R122\", \"subject\": \"Bathroom tap leaking\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 03:10:00'),
(1452, 502, 'Ticket Submitted', 'maintenance_tickets', '190', NULL, '{\"ticket_number\": \"TCK-HF-260827-E-R143\", \"subject\": \"Bathroom tap eka leak wenawa\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 04:23:00'),
(1453, 503, 'Ticket Submitted', 'maintenance_tickets', '191', NULL, '{\"ticket_number\": \"TCK-HF-260827-E-R144\", \"subject\": \"Drain water flowing slowly\", \"language_type\": \"Sinhala\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 05:36:00'),
(1454, 504, 'Ticket Submitted', 'maintenance_tickets', '192', NULL, '{\"ticket_number\": \"TCK-HF-260827-E-R145\", \"subject\": \"Pest activity in kitchen\", \"language_type\": \"Mixed\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 06:49:00'),
(1455, 505, 'Ticket Submitted', 'maintenance_tickets', '193', NULL, '{\"ticket_number\": \"TCK-HF-260827-E-R146\", \"subject\": \"Loose fitting needs repair\", \"language_type\": \"Singlish\"}', 'Synthetic test ticket submission used to validate the resident maintenance workflow.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 08:02:00'),
(1459, 272, 'AI Analysis', 'maintenance_tickets', '147', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 198, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 00:04:02'),
(1460, 273, 'AI Analysis', 'maintenance_tickets', '183', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 175, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 19:52:02'),
(1461, 274, 'AI Analysis', 'maintenance_tickets', '159', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 158, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 14:40:02'),
(1462, 275, 'AI Analysis', 'maintenance_tickets', '148', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": \"TCK-HF-260827-B-R087\", \"duplicate_similarity\": 0.95000, \"recommended_technician\": 198, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 01:17:02'),
(1463, 276, 'AI Analysis', 'maintenance_tickets', '172', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 213, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 06:29:02'),
(1464, 277, 'AI Analysis', 'maintenance_tickets', '134', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 206, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 08:15:02'),
(1465, 278, 'AI Analysis', 'maintenance_tickets', '149', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 201, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 02:30:02'),
(1466, 279, 'AI Analysis', 'maintenance_tickets', '173', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": \"TCK-HF-260827-D-R091\", \"duplicate_similarity\": 0.95000, \"recommended_technician\": 213, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 07:42:02'),
(1467, 280, 'AI Analysis', 'maintenance_tickets', '135', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": \"TCK-HF-260827-A-R092\", \"duplicate_similarity\": 0.92000, \"recommended_technician\": 206, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 09:28:02'),
(1468, 281, 'AI Analysis', 'maintenance_tickets', '160', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": \"TCK-HF-260827-C-R089\", \"duplicate_similarity\": 0.92000, \"recommended_technician\": 158, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 15:53:02'),
(1469, 282, 'AI Analysis', 'maintenance_tickets', '150', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": \"TCK-HF-260827-B-R093\", \"duplicate_similarity\": 0.92000, \"recommended_technician\": 201, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 03:43:02'),
(1470, 283, 'AI Analysis', 'maintenance_tickets', '161', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 171, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 17:06:02'),
(1471, 284, 'AI Analysis', 'maintenance_tickets', '174', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 215, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 08:55:02'),
(1472, 285, 'AI Analysis', 'maintenance_tickets', '136', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 173, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 10:41:02'),
(1473, 286, 'AI Analysis', 'maintenance_tickets', '162', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": \"TCK-HF-260827-C-R098\", \"duplicate_similarity\": 0.94000, \"recommended_technician\": 171, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 18:19:02'),
(1474, 287, 'AI Analysis', 'maintenance_tickets', '184', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": \"TCK-HF-260827-E-R088\", \"duplicate_similarity\": 0.91000, \"recommended_technician\": 175, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 21:05:02'),
(1475, 288, 'AI Analysis', 'maintenance_tickets', '137', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": \"TCK-HF-260827-A-R100\", \"duplicate_similarity\": 0.94000, \"recommended_technician\": 173, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 11:54:02'),
(1476, 289, 'AI Analysis', 'maintenance_tickets', '185', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 172, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 22:18:02'),
(1477, 290, 'AI Analysis', 'maintenance_tickets', '175', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": \"TCK-HF-260827-D-R099\", \"duplicate_similarity\": 0.92000, \"recommended_technician\": 215, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 10:08:02'),
(1478, 291, 'AI Analysis', 'maintenance_tickets', '138', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 68.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 207, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 13:07:02'),
(1479, 292, 'AI Analysis', 'maintenance_tickets', '139', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 68.00, \"risk_level\": \"High\", \"duplicate\": \"TCK-HF-260827-A-R106\", \"duplicate_similarity\": 0.91000, \"recommended_technician\": 207, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 14:20:02'),
(1480, 293, 'AI Analysis', 'maintenance_tickets', '186', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": \"TCK-HF-260827-E-R104\", \"duplicate_similarity\": 0.93000, \"recommended_technician\": 172, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 23:31:02'),
(1481, 294, 'AI Analysis', 'maintenance_tickets', '151', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 68.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 167, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 04:56:02'),
(1482, 295, 'AI Analysis', 'maintenance_tickets', '140', NULL, '{\"category\": \"Carpentry\", \"priority\": \"Low\", \"risk_score\": 25.00, \"risk_level\": \"Low\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 199, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 15:33:02'),
(1483, 296, 'AI Analysis', 'maintenance_tickets', '163', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 68.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 152, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 19:32:02'),
(1484, 297, 'AI Analysis', 'maintenance_tickets', '141', NULL, '{\"category\": \"Security and Access\", \"priority\": \"High\", \"risk_score\": 65.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 178, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 16:46:02'),
(1485, 298, 'AI Analysis', 'maintenance_tickets', '187', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 68.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 170, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 00:44:02');
INSERT INTO `audit_logs` (`audit_id`, `user_id`, `action_type`, `entity_type`, `entity_id`, `old_value`, `new_value`, `reason`, `ip_address`, `user_agent`, `created_at`) VALUES
(1486, 299, 'AI Analysis', 'maintenance_tickets', '152', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 68.00, \"risk_level\": \"High\", \"duplicate\": \"TCK-HF-260827-B-R109\", \"duplicate_similarity\": 0.94000, \"recommended_technician\": 167, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 06:09:02'),
(1487, 300, 'AI Analysis', 'maintenance_tickets', '164', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 68.00, \"risk_level\": \"High\", \"duplicate\": \"TCK-HF-260827-C-R111\", \"duplicate_similarity\": 0.91000, \"recommended_technician\": 152, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 20:45:02'),
(1488, 301, 'AI Analysis', 'maintenance_tickets', '176', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 68.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 204, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 11:21:02'),
(1489, 302, 'AI Analysis', 'maintenance_tickets', '188', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 68.00, \"risk_level\": \"High\", \"duplicate\": \"TCK-HF-260827-E-R113\", \"duplicate_similarity\": 0.95000, \"recommended_technician\": 170, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 01:57:02'),
(1490, 303, 'AI Analysis', 'maintenance_tickets', '153', NULL, '{\"category\": \"Pest Control\", \"priority\": \"Low\", \"risk_score\": 28.00, \"risk_level\": \"Low\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 184, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 07:22:02'),
(1491, 304, 'AI Analysis', 'maintenance_tickets', '177', NULL, '{\"category\": \"Electrical\", \"priority\": \"High\", \"risk_score\": 68.00, \"risk_level\": \"High\", \"duplicate\": \"TCK-HF-260827-D-R116\", \"duplicate_similarity\": 0.94000, \"recommended_technician\": 204, \"auto_assignment\": 0, \"manual_review_required\": 1, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate duplicate-ticket detection and review.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 12:34:02'),
(1492, 305, 'AI Analysis', 'maintenance_tickets', '165', NULL, '{\"category\": \"Structural\", \"priority\": \"High\", \"risk_score\": 72.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 193, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 21:58:02'),
(1493, 306, 'AI Analysis', 'maintenance_tickets', '154', NULL, '{\"category\": \"Security and Access\", \"priority\": \"High\", \"risk_score\": 65.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 177, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 08:35:02'),
(1494, 307, 'AI Analysis', 'maintenance_tickets', '189', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 172, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 03:10:02'),
(1495, 308, 'AI Analysis', 'maintenance_tickets', '166', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 171, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 23:11:02'),
(1496, 309, 'AI Analysis', 'maintenance_tickets', '178', NULL, '{\"category\": \"Drainage\", \"priority\": \"High\", \"risk_score\": 62.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 215, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 13:47:02'),
(1497, 484, 'AI Analysis', 'maintenance_tickets', '142', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 173, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 17:59:02'),
(1498, 485, 'AI Analysis', 'maintenance_tickets', '143', NULL, '{\"category\": \"Drainage\", \"priority\": \"High\", \"risk_score\": 62.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 173, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 19:12:02'),
(1499, 486, 'AI Analysis', 'maintenance_tickets', '144', NULL, '{\"category\": \"Pest Control\", \"priority\": \"Low\", \"risk_score\": 28.00, \"risk_level\": \"Low\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 181, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 20:25:02'),
(1500, 487, 'AI Analysis', 'maintenance_tickets', '145', NULL, '{\"category\": \"Other\", \"priority\": \"Medium\", \"risk_score\": 38.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 153, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 21:38:02'),
(1501, 488, 'AI Analysis', 'maintenance_tickets', '146', NULL, '{\"category\": \"Security and Access\", \"priority\": \"High\", \"risk_score\": 65.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 178, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-24 22:51:02'),
(1502, 489, 'AI Analysis', 'maintenance_tickets', '155', NULL, '{\"category\": \"Structural\", \"priority\": \"High\", \"risk_score\": 72.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 164, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 09:48:02'),
(1503, 490, 'AI Analysis', 'maintenance_tickets', '156', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 198, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 11:01:02'),
(1504, 491, 'AI Analysis', 'maintenance_tickets', '157', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 201, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 12:14:02'),
(1505, 492, 'AI Analysis', 'maintenance_tickets', '158', NULL, '{\"category\": \"Drainage\", \"priority\": \"High\", \"risk_score\": 62.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 201, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-25 13:27:02'),
(1506, 493, 'AI Analysis', 'maintenance_tickets', '167', NULL, '{\"category\": \"Air Conditioning\", \"priority\": \"Medium\", \"risk_score\": 42.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 169, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 00:24:02'),
(1507, 494, 'AI Analysis', 'maintenance_tickets', '168', NULL, '{\"category\": \"Cleaning\", \"priority\": \"Low\", \"risk_score\": 22.00, \"risk_level\": \"Low\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 176, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 01:37:02'),
(1508, 495, 'AI Analysis', 'maintenance_tickets', '169', NULL, '{\"category\": \"Carpentry\", \"priority\": \"Low\", \"risk_score\": 25.00, \"risk_level\": \"Low\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 182, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 02:50:02'),
(1509, 496, 'AI Analysis', 'maintenance_tickets', '170', NULL, '{\"category\": \"Structural\", \"priority\": \"High\", \"risk_score\": 72.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 193, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 04:03:02'),
(1510, 497, 'AI Analysis', 'maintenance_tickets', '171', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 158, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 05:16:02'),
(1511, 498, 'AI Analysis', 'maintenance_tickets', '179', NULL, '{\"category\": \"Structural\", \"priority\": \"High\", \"risk_score\": 72.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 166, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 15:00:02'),
(1512, 499, 'AI Analysis', 'maintenance_tickets', '180', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 64.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 213, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 16:13:02'),
(1513, 500, 'AI Analysis', 'maintenance_tickets', '181', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 215, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 17:26:02'),
(1514, 501, 'AI Analysis', 'maintenance_tickets', '182', NULL, '{\"category\": \"Drainage\", \"priority\": \"High\", \"risk_score\": 62.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 215, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-26 18:39:02'),
(1515, 502, 'AI Analysis', 'maintenance_tickets', '190', NULL, '{\"category\": \"Plumbing\", \"priority\": \"Medium\", \"risk_score\": 48.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 172, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 04:23:02'),
(1516, 503, 'AI Analysis', 'maintenance_tickets', '191', NULL, '{\"category\": \"Drainage\", \"priority\": \"High\", \"risk_score\": 62.00, \"risk_level\": \"High\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 172, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Sinhala\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 05:36:02'),
(1517, 504, 'AI Analysis', 'maintenance_tickets', '192', NULL, '{\"category\": \"Pest Control\", \"priority\": \"Low\", \"risk_score\": 28.00, \"risk_level\": \"Low\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 190, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Mixed\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 06:49:02'),
(1518, 505, 'AI Analysis', 'maintenance_tickets', '193', NULL, '{\"category\": \"Other\", \"priority\": \"Medium\", \"risk_score\": 38.00, \"risk_level\": \"Medium\", \"duplicate\": null, \"duplicate_similarity\": null, \"recommended_technician\": 195, \"auto_assignment\": 0, \"manual_review_required\": 0, \"language_type\": \"Singlish\"}', 'Synthetic test AI analysis used to validate classification, prioritisation and recommendation.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 08:02:02'),
(1522, 15, 'Maintenance Ticket Records Created', 'ticket_batch', 'TICKETS-AUG2026-RES60', NULL, '{\"total_tickets\": 60, \"english_tickets\": 0, \"sinhala_tickets\": 22, \"singlish_tickets\": 24, \"mixed_tickets\": 14, \"duplicate_tickets\": 15, \"buildings\": 5, \"period_start\": \"2026-08-24\", \"period_end\": \"2026-08-27\"}', 'Sixty synthetic multilingual resident maintenance tickets were prepared for controlled workflow, AI and duplicate-detection testing across all five buildings.', '127.0.0.1', 'HelaFixIt AI Test Data', '2026-08-27 12:50:00'),
(1523, 277, 'Ticket Submitted', 'maintenance_tickets', '194', NULL, '{\"ticket_number\": \"TCK-260829-A760403F\", \"subject\": \"\\u0db1\\u0dcf\\u0db1 \\u0d9a\\u0dcf\\u0db8\\u0dbb\\u0dba\\u0dda \\u0da2\\u0dbd \\u0db1\\u0dc5\\u0dba \\u0d9a\\u0dd0\\u0da9\\u0dd3 \\u0da2\\u0dbd\\u0dba \\u0d9c\\u0dbd\\u0dcf \\u0dba\\u0dcf\\u0db8\"}', 'Resident submitted a live maintenance ticket through the Flask application.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-29 10:31:11'),
(1524, 277, 'AI Analysis', 'maintenance_tickets', '194', NULL, '{\"category\": \"Plumbing\", \"priority\": \"High\", \"risk_score\": 54.7, \"risk_level\": \"Medium\", \"duplicate\": null, \"recommended_technician\": 173, \"auto_assignment\": false}', 'Local HelaFixIt AI ticket decision process.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-29 10:31:14'),
(1525, 335, 'Ticket Review', 'maintenance_tickets', '194', '{\"category_id\": 2, \"priority\": \"High\"}', '{\"category_id\": 2, \"priority\": \"High\"}', 'Apartment admin reviewed the live ticket.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-29 10:32:42'),
(1526, 335, 'Technician Assigned', 'maintenance_tickets', '194', NULL, '{\"technician_id\": 173, \"method\": \"Manual\"}', 'Manual assignment by apartment admin.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-29 10:32:58'),
(1527, 301, 'Ticket Submitted', 'maintenance_tickets', '195', NULL, '{\"ticket_number\": \"TCK-260829-DD29D052\", \"subject\": \"Kitchen eke plug point eka spark wenawa\"}', 'Resident submitted a live maintenance ticket through the Flask application.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-29 11:08:29'),
(1528, 301, 'AI Analysis', 'maintenance_tickets', '195', NULL, '{\"category\": \"Electrical\", \"priority\": \"Emergency\", \"risk_score\": 100.0, \"risk_level\": \"Critical\", \"duplicate\": null, \"recommended_technician\": 204, \"auto_assignment\": true}', 'Local HelaFixIt AI ticket decision process.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-29 11:08:31'),
(1529, 504, 'PROFILE_UPDATED', 'User', '504', NULL, NULL, 'Resident updated own profile', NULL, NULL, '2026-08-29 12:26:00'),
(1530, 15, 'PASSWORD_RESET_BY_ADMIN', 'User', '505', NULL, NULL, 'Temporary password issued by System Admin; password change required at next sign in', NULL, NULL, '2026-08-29 12:35:38'),
(1531, 505, 'PASSWORD_CHANGED', 'User', '505', NULL, NULL, 'User changed password', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-29 12:36:13'),
(1532, 342, 'Technician Assigned', 'maintenance_tickets', '193', NULL, '{\"technician_id\": 195, \"method\": \"Manual\"}', 'Manual assignment by apartment admin.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-29 13:45:04'),
(1533, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '1', NULL, '{\"full_name\": \"Ayesha Wickramanayake\", \"email\": \"ayesha.wickramanayake@outlook.com\", \"phone\": \"+94780309415\", \"building\": \"Block C\", \"floor\": 8, \"unit\": \"C-807\", \"resident_type\": \"Owner\", \"preferred_language\": \"English\", \"contact_preference\": \"In App\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.30.24', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-24 15:03:00'),
(1534, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '2', NULL, '{\"full_name\": \"Chathurika Ranasinghe\", \"email\": \"chathurika.ranasinghe@gmail.com\", \"phone\": \"+94713100941\", \"building\": \"Block B\", \"floor\": 6, \"unit\": \"B-607\", \"resident_type\": \"Family\", \"preferred_language\": \"Sinhala\", \"contact_preference\": \"Phone\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.20.49', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-26 13:14:00'),
(1535, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '3', NULL, '{\"full_name\": \"Dasun Rathnayake\", \"email\": \"dasun.rathnayake@outlook.com\", \"phone\": \"+94786707442\", \"building\": \"Block D\", \"floor\": 3, \"unit\": \"D-304\", \"resident_type\": \"Tenant\", \"preferred_language\": \"English\", \"contact_preference\": \"In App\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.40.33', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-26 10:12:00'),
(1536, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '4', NULL, '{\"full_name\": \"Dinesh Karunaratne\", \"email\": \"dinesh.karunaratne@gmail.com\", \"phone\": \"+94771952088\", \"building\": \"Block C\", \"floor\": 10, \"unit\": \"C-1003\", \"resident_type\": \"Tenant\", \"preferred_language\": \"Singlish\", \"contact_preference\": \"SMS\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.30.42', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-25 17:21:00'),
(1537, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '5', NULL, '{\"full_name\": \"Hirushi Senanayake\", \"email\": \"hirushi.senanayake@live.com\", \"phone\": \"+94780645485\", \"building\": \"Block D\", \"floor\": 6, \"unit\": \"D-603\", \"resident_type\": \"Family\", \"preferred_language\": \"Sinhala\", \"contact_preference\": \"Email\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.40.61', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-28 14:07:00'),
(1538, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '6', NULL, '{\"full_name\": \"Imalka Herath\", \"email\": \"imalka.herath@gmail.com\", \"phone\": \"+94752525020\", \"building\": \"Block E\", \"floor\": 6, \"unit\": \"E-607\", \"resident_type\": \"Other\", \"preferred_language\": \"English\", \"contact_preference\": \"SMS\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.50.79', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-28 16:31:00'),
(1539, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '7', NULL, '{\"full_name\": \"Isuru Weerakoon\", \"email\": \"isuru.weerakoon@live.com\", \"phone\": \"+94726934178\", \"building\": \"Block B\", \"floor\": 5, \"unit\": \"B-506\", \"resident_type\": \"Owner\", \"preferred_language\": \"English\", \"contact_preference\": \"In App\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.20.37', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-25 08:55:00'),
(1540, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '8', NULL, '{\"full_name\": \"Kaveesha Nadeeshani\", \"email\": \"kaveesha.nadeeshani@hotmail.com\", \"phone\": \"+94743250906\", \"building\": \"Block C\", \"floor\": 15, \"unit\": \"C-1505\", \"resident_type\": \"Owner\", \"preferred_language\": \"Mixed\", \"contact_preference\": \"Phone\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.30.69', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-28 11:53:00'),
(1541, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '9', NULL, '{\"full_name\": \"Kavindu Dissanayake\", \"email\": \"kavindu.dissanayake@icloud.com\", \"phone\": \"+94756397011\", \"building\": \"Block E\", \"floor\": 2, \"unit\": \"E-203\", \"resident_type\": \"Tenant\", \"preferred_language\": \"English\", \"contact_preference\": \"Email\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.50.29', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-25 12:16:00'),
(1542, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '10', NULL, '{\"full_name\": \"Lakmini Weerasinghe\", \"email\": \"lakmini.weerasinghe@outlook.com\", \"phone\": \"+94724893138\", \"building\": \"Block E\", \"floor\": 4, \"unit\": \"E-405\", \"resident_type\": \"Owner\", \"preferred_language\": \"Mixed\", \"contact_preference\": \"Phone\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.50.53', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-27 09:27:00'),
(1543, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '11', NULL, '{\"full_name\": \"Menaka Rodrigo\", \"email\": \"menaka.rodrigo@hotmail.com\", \"phone\": \"+94768008579\", \"building\": \"Block A\", \"floor\": 12, \"unit\": \"A-1203\", \"resident_type\": \"Family\", \"preferred_language\": \"Mixed\", \"contact_preference\": \"Phone\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.10.58', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-27 11:47:00'),
(1544, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '12', NULL, '{\"full_name\": \"Nadeesha Gunasekara\", \"email\": \"nadeesha.gunasekara@hotmail.com\", \"phone\": \"+94707367209\", \"building\": \"Block E\", \"floor\": 3, \"unit\": \"E-304\", \"resident_type\": \"Family\", \"preferred_language\": \"Sinhala\", \"contact_preference\": \"In App\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.50.41', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-26 15:44:00'),
(1545, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '13', NULL, '{\"full_name\": \"Nethmi Abeysekara\", \"email\": \"nethmi.abeysekara@outlook.com\", \"phone\": \"+94708449238\", \"building\": \"Block B\", \"floor\": 3, \"unit\": \"B-304\", \"resident_type\": \"Tenant\", \"preferred_language\": \"Singlish\", \"contact_preference\": \"Email\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.20.21', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-24 10:26:00'),
(1546, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '14', NULL, '{\"full_name\": \"Ruvini Gamage\", \"email\": \"ruvini.gamage@icloud.com\", \"phone\": \"+94754969928\", \"building\": \"Block C\", \"floor\": 12, \"unit\": \"C-1204\", \"resident_type\": \"Family\", \"preferred_language\": \"Sinhala\", \"contact_preference\": \"Email\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.30.55', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-27 08:36:00'),
(1547, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '15', NULL, '{\"full_name\": \"Sahan Lakmal\", \"email\": \"sahan.lakmal@icloud.com\", \"phone\": \"+94787316723\", \"building\": \"Block B\", \"floor\": 9, \"unit\": \"B-903\", \"resident_type\": \"Tenant\", \"preferred_language\": \"Mixed\", \"contact_preference\": \"SMS\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.20.63', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-27 16:08:00'),
(1548, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '16', NULL, '{\"full_name\": \"Savindi Perera\", \"email\": \"savindi.perera26@gmail.com\", \"phone\": \"+94770125001\", \"building\": \"Block A\", \"floor\": 5, \"unit\": \"A-504\", \"resident_type\": \"Owner\", \"preferred_language\": \"English\", \"contact_preference\": \"In App\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.10.31', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-24 09:18:00'),
(1549, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '17', NULL, '{\"full_name\": \"Shashika Fernando\", \"email\": \"shashika.fernando@gmail.com\", \"phone\": \"+94709947460\", \"building\": \"Block E\", \"floor\": 1, \"unit\": \"E-102\", \"resident_type\": \"Owner\", \"preferred_language\": \"Singlish\", \"contact_preference\": \"SMS\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.50.18', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-24 11:39:00'),
(1550, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '18', NULL, '{\"full_name\": \"Tharindu Jayasinghe\", \"email\": \"tharindu.jayasinghe@icloud.com\", \"phone\": \"+94764149380\", \"building\": \"Block A\", \"floor\": 10, \"unit\": \"A-1005\", \"resident_type\": \"Tenant\", \"preferred_language\": \"Sinhala\", \"contact_preference\": \"SMS\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.10.44', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-25 14:32:00'),
(1551, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '19', NULL, '{\"full_name\": \"Thisara Bandara\", \"email\": \"thisara.bandara@live.com\", \"phone\": \"+94716733885\", \"building\": \"Block E\", \"floor\": 5, \"unit\": \"E-506\", \"resident_type\": \"Tenant\", \"preferred_language\": \"Singlish\", \"contact_preference\": \"In App\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.50.67', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-28 08:19:00'),
(1552, NULL, 'REGISTRATION_REQUEST_SUBMITTED', 'resident_registration_requests', '20', NULL, '{\"full_name\": \"Vihanga Peiris\", \"email\": \"vihanga.peiris@hotmail.com\", \"phone\": \"+94748539641\", \"building\": \"Block B\", \"floor\": 10, \"unit\": \"B-1004\", \"resident_type\": \"Other\", \"preferred_language\": \"English\", \"contact_preference\": \"Email\", \"status\": \"Pending\"}', 'Resident registration request submitted through the HelaFixIt AI registration portal.', '192.168.20.76', 'Mozilla/5.0 HelaFixIt Resident Registration', '2026-08-28 09:41:00'),
(1564, 15, 'REGISTRATION_REJECTED', 'resident_registration_requests', '6', NULL, NULL, 'Registration request rejected.', NULL, NULL, '2026-08-29 14:04:09'),
(1565, 15, 'REGISTRATION_APPROVED', 'resident_registration_requests', '16', NULL, '{\"created_user_id\": 506}', 'Registration approved.', NULL, NULL, '2026-08-29 14:04:27'),
(1566, 341, 'REGISTRATION_APPROVED', 'resident_registration_requests', '32', NULL, '{\"created_user_id\": 507}', 'Approved', NULL, NULL, '2026-08-29 14:10:46'),
(1567, 15, 'SETTINGS_UPDATED', 'system_settings', NULL, NULL, '{\"system_name\": \"HelaFixIt AI\", \"apartment_name\": \"Hela Residence\", \"emergency_risk_threshold\": 86, \"duplicate_similarity_threshold\": 0.72, \"low_confidence_threshold\": 0.65, \"max_upload_mb\": 5, \"allowed_image_types\": \"jpg,jpeg,png,webp\", \"default_language\": \"English\", \"technician_default_max_jobs\": 4, \"notification_retention_days\": 90, \"registration_requires_approval\": true, \"auto_emergency_assignment\": true, \"maintenance_mode\": false, \"allow_registration\": true, \"email_alerts\": false, \"sms_alerts\": false, \"browser_alerts\": true}', 'System settings updated', NULL, NULL, '2026-08-29 18:34:15'),
(1568, 15, 'PASSWORD_RESET_BY_ADMIN', 'User', '506', NULL, NULL, 'Temporary password issued by System Admin; password change required at next sign in', NULL, NULL, '2026-08-29 18:37:52'),
(1569, 506, 'PASSWORD_CHANGED', 'User', '506', NULL, NULL, 'User changed password', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-29 18:38:26'),
(1570, 480, 'USER_UPDATED', 'User', '506', NULL, '{\"status\": \"Suspended\", \"email_verified\": 1}', 'User account updated by System Admin', NULL, NULL, '2026-08-29 18:40:14'),
(1571, 405, 'PROFILE_UPDATED', 'User', '405', NULL, NULL, 'Technician updated own profile', NULL, NULL, '2026-08-29 18:48:37'),
(1572, 15, 'SKILL_UPDATED', 'Skill', '4', '{\"skill_id\": 4, \"skill_name\": \"AC Technician\", \"description\": \"Air conditioning and ventilation maintenance\", \"active\": 1}', '{\"name\": \"AC Technician\", \"description\": \"Air conditioning and ventilation maintenance\"}', 'Technician skill updated.', NULL, NULL, '2026-08-30 00:16:03'),
(1573, 277, 'Ticket Submitted', 'maintenance_tickets', '196', NULL, '{\"ticket_number\": \"TCK-260830-8887E2EA\", \"subject\": \"Lift eke door eka move wenakota open wenawa\"}', 'Resident submitted a live maintenance ticket through the Flask application.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 00:27:49'),
(1574, 277, 'AI Analysis', 'maintenance_tickets', '196', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 62.7, \"risk_level\": \"High\", \"duplicate\": null, \"recommended_technician\": 206, \"auto_assignment\": false}', 'Local HelaFixIt AI ticket decision process.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 00:27:53'),
(1575, 335, 'AI Analysis', 'maintenance_tickets', '196', NULL, '{\"category\": \"Lift\", \"priority\": \"High\", \"risk_score\": 62.7, \"risk_level\": \"High\", \"duplicate\": null, \"recommended_technician\": 206, \"auto_assignment\": false}', 'Local HelaFixIt AI ticket decision process.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 00:28:43'),
(1576, 335, 'Ticket Review', 'maintenance_tickets', '196', '{\"category_id\": 3, \"priority\": \"High\"}', '{\"category_id\": 3, \"priority\": \"High\"}', 'Apartment admin reviewed the live ticket.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 00:28:53'),
(1577, 335, 'Technician Assigned', 'maintenance_tickets', '196', NULL, '{\"technician_id\": 206, \"method\": \"Manual\"}', 'Manual assignment by apartment admin.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 00:29:12'),
(1578, 501, 'Ticket Submitted', 'maintenance_tickets', '197', NULL, '{\"ticket_number\": \"TCK-260830-D5AC82E9\", \"subject\": \"Main electrical panel eke wires eliyata awilla\"}', 'Resident submitted a live maintenance ticket through the Flask application.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 00:37:08'),
(1579, 501, 'AI Analysis', 'maintenance_tickets', '197', NULL, '{\"category\": \"Electrical\", \"priority\": \"Emergency\", \"risk_score\": 100.0, \"risk_level\": \"Critical\", \"duplicate\": null, \"recommended_technician\": 204, \"auto_assignment\": true}', 'Local HelaFixIt AI ticket decision process.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 00:37:09'),
(1580, 15, 'PASSWORD_RESET_BY_ADMIN', 'User', '505', NULL, NULL, 'Temporary password issued by System Admin; password change required at next sign in', NULL, NULL, '2026-08-30 01:18:20'),
(1581, 15, 'USER_UNLOCKED', 'User', '506', NULL, NULL, 'Account unlocked by System Admin', NULL, NULL, '2026-08-30 01:41:40'),
(1582, 15, 'USER_UPDATED', 'User', '506', NULL, '{\"status\": \"Active\", \"email_verified\": 1}', 'User account updated by System Admin', NULL, NULL, '2026-08-30 01:41:53'),
(1583, 15, 'USER_UPDATED', 'User', '506', NULL, '{\"status\": \"Suspended\", \"email_verified\": 1}', 'User account updated by System Admin', NULL, NULL, '2026-08-30 01:42:06'),
(1584, 15, 'TEMPORARY_PASSWORD_ISSUED', 'User', '306', NULL, '{\"expires_hours\": 24}', 'Temporary password issued by System Admin; normal password retained until user creates a new password', NULL, NULL, '2026-08-30 01:42:42'),
(1585, 306, 'TEMPORARY_PASSWORD_REPLACED', 'User', '306', NULL, NULL, 'User created a new normal password after temporary password sign in', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 01:43:53'),
(1586, 306, 'Ticket Submitted', 'maintenance_tickets', '198', NULL, '{\"ticket_number\": \"TCK-260830-30BE14C5\", \"subject\": \"\\u0db1\\u0dcf\\u0db1 \\u0d9a\\u0dcf\\u0db8\\u0dbb\\u0dba\\u0dda \\u0dc0\\u0dad\\u0dd4\\u0dbb \\u0dc4\\u0dd3\\u0da7\\u0dbb\\u0dba\\u0dd9\\u0db1\\u0dca \\u0dc0\\u0dd2\\u0daf\\u0dd4\\u0dbd\\u0dd2 \\u0dc3\\u0dd0\\u0dbb \\u0dc0\\u0daf\\u0dd2\\u0db1\\u0dc0\\u0dcf\"}', 'Resident submitted a live maintenance ticket through the Flask application.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 01:51:16'),
(1587, 306, 'AI Analysis', 'maintenance_tickets', '198', NULL, '{\"category\": \"Electrical\", \"priority\": \"Emergency\", \"risk_score\": 100.0, \"risk_level\": \"Critical\", \"duplicate\": null, \"recommended_technician\": 167, \"auto_assignment\": true}', 'Local HelaFixIt AI ticket decision process.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 01:51:18'),
(1588, 505, 'PASSWORD_RESET_REQUESTED', 'User', '505', NULL, NULL, 'Forgot Password request submitted', '127.0.0.1', NULL, '2026-08-30 10:03:48'),
(1589, 481, 'TEMPORARY_PASSWORD_ISSUED', 'User', '505', NULL, '{\"expires_hours\": 24}', 'Temporary password issued by System Admin; normal password retained until user creates a new password', NULL, NULL, '2026-08-30 10:05:24'),
(1590, 505, 'TEMPORARY_PASSWORD_REPLACED', 'User', '505', NULL, NULL, 'User created a new normal password after temporary password sign in', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 10:07:06'),
(1591, 505, 'Ticket Submitted', 'maintenance_tickets', '199', NULL, '{\"ticket_number\": \"TCK-260830-61E0D456\", \"subject\": \"Main door lock eka kadila\"}', 'Resident submitted a live maintenance ticket through the Flask application.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 10:13:44'),
(1592, 505, 'AI Analysis', 'maintenance_tickets', '199', NULL, '{\"category\": \"Security and Access\", \"priority\": \"High\", \"risk_score\": 76.0, \"risk_level\": \"High\", \"duplicate\": null, \"recommended_technician\": 212, \"auto_assignment\": false}', 'Local HelaFixIt AI ticket decision process.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 10:13:47'),
(1593, 338, 'Ticket Review', 'maintenance_tickets', '199', '{\"category_id\": 13, \"priority\": \"High\"}', '{\"category_id\": 13, \"priority\": \"High\"}', 'Apartment admin reviewed the live ticket.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 10:15:19'),
(1594, 338, 'Technician Assigned', 'maintenance_tickets', '199', NULL, '{\"technician_id\": 212, \"method\": \"Manual\"}', 'Manual assignment by apartment admin.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 10:15:33'),
(1595, 307, 'Ticket Submitted', 'maintenance_tickets', '200', NULL, '{\"ticket_number\": \"TCK-260830-8B683F17\", \"subject\": \"Electrical room eke smoke saha burning smell enawa\"}', 'Resident submitted a live maintenance ticket through the Flask application.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 10:22:03'),
(1596, 307, 'AI Analysis', 'maintenance_tickets', '200', NULL, '{\"category\": \"Fire and Safety\", \"priority\": \"Emergency\", \"risk_score\": 100.0, \"risk_level\": \"Critical\", \"duplicate\": null, \"recommended_technician\": 197, \"auto_assignment\": true}', 'Local HelaFixIt AI ticket decision process.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 10:22:04'),
(1597, 395, 'PASSWORD_RESET_REQUESTED', 'User', '395', NULL, NULL, 'Forgot Password request submitted', '127.0.0.1', NULL, '2026-08-30 10:25:48'),
(1598, 498, 'Ticket Submitted', 'maintenance_tickets', '201', NULL, '{\"ticket_number\": \"TCK-260830-8A3C97B0\", \"subject\": \"\\u0d9a\\u0ddc\\u0dbb\\u0dd2\\u0da9\\u0ddd\\u0dc0\\u0dda \\u0dc3\\u0dd2\\u0dc0\\u0dd2\\u0dbd\\u0dd2\\u0db8\\u0dd9\\u0db1\\u0dca \\u0dc0\\u0dd2\\u0dc1\\u0dcf\\u0dbd \\u0dc0\\u0dad\\u0dd4\\u0dbb \\u0d9a\\u0dcf\\u0db1\\u0dca\\u0daf\\u0dd4\\u0dc0\\u0d9a\\u0dca\"}', 'Resident submitted a live maintenance ticket through the Flask application.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 16:34:15'),
(1599, 498, 'AI Analysis', 'maintenance_tickets', '201', NULL, '{\"category\": \"Electrical\", \"priority\": \"Emergency\", \"risk_score\": 100.0, \"risk_level\": \"Critical\", \"duplicate\": null, \"recommended_technician\": 204, \"auto_assignment\": true}', 'Local HelaFixIt AI ticket decision process.', '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', '2026-08-30 16:34:18');

-- --------------------------------------------------------

--
-- Table structure for table `backup_records`
--

CREATE TABLE `backup_records` (
  `backup_id` bigint(20) UNSIGNED NOT NULL,
  `started_by` bigint(20) UNSIGNED DEFAULT NULL,
  `backup_type` enum('Manual','Automatic','Full','Schema','Data') NOT NULL DEFAULT 'Manual',
  `file_name` varchar(255) DEFAULT NULL,
  `file_location` varchar(500) DEFAULT NULL,
  `backup_status` enum('Started','Completed','Failed','Restored') NOT NULL DEFAULT 'Started',
  `size_bytes` bigint(20) UNSIGNED DEFAULT NULL,
  `checksum_sha256` char(64) DEFAULT NULL,
  `started_at` datetime NOT NULL DEFAULT current_timestamp(),
  `completed_at` datetime DEFAULT NULL,
  `restored_at` datetime DEFAULT NULL,
  `restored_by` bigint(20) UNSIGNED DEFAULT NULL,
  `notes` varchar(1000) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `backup_records`
--

INSERT INTO `backup_records` (`backup_id`, `started_by`, `backup_type`, `file_name`, `file_location`, `backup_status`, `size_bytes`, `checksum_sha256`, `started_at`, `completed_at`, `restored_at`, `restored_by`, `notes`) VALUES
(1, 15, 'Data', 'helafixit_data_export.json', 'Browser download', 'Completed', NULL, NULL, '2026-08-29 13:38:38', '2026-08-29 13:38:38', NULL, NULL, 'JSON export generated from live database');

-- --------------------------------------------------------

--
-- Table structure for table `buildings`
--

CREATE TABLE `buildings` (
  `building_id` bigint(20) UNSIGNED NOT NULL,
  `complex_id` bigint(20) UNSIGNED NOT NULL,
  `name` varchar(150) NOT NULL,
  `block_code` varchar(50) NOT NULL,
  `address_label` varchar(255) DEFAULT NULL,
  `declared_floor_count` smallint(5) UNSIGNED DEFAULT NULL,
  `declared_unit_count` smallint(5) UNSIGNED DEFAULT NULL,
  `status` enum('Active','Inactive') NOT NULL DEFAULT 'Active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `buildings`
--

INSERT INTO `buildings` (`building_id`, `complex_id`, `name`, `block_code`, `address_label`, `declared_floor_count`, `declared_unit_count`, `status`, `created_at`, `updated_at`) VALUES
(1, 1, 'Hela Residence Block A', 'Block A', 'Block A', 16, 96, 'Active', '2026-08-15 13:50:19', '2026-08-27 12:45:39'),
(2, 1, 'Hela Residence Block B', 'Block B', 'Block B', 15, 80, 'Active', '2026-08-15 13:50:19', '2026-08-27 14:08:00'),
(3, 1, 'Hela Residence Block C', 'Block C', 'Block C', 16, 120, 'Active', '2026-08-15 13:50:19', '2026-08-27 12:45:39'),
(4, 1, 'Hela Residence Block D', 'Block D', NULL, 10, 80, 'Active', '2026-08-23 16:14:57', '2026-08-27 12:45:39'),
(7, 1, 'Hela Residence Block E', 'Block E', NULL, 11, 75, 'Active', '2026-08-23 16:15:24', '2026-08-27 12:45:39');

-- --------------------------------------------------------

--
-- Table structure for table `category_skill_mappings`
--

CREATE TABLE `category_skill_mappings` (
  `category_skill_mapping_id` bigint(20) UNSIGNED NOT NULL,
  `category_id` bigint(20) UNSIGNED NOT NULL,
  `skill_id` bigint(20) UNSIGNED NOT NULL,
  `required_level` enum('Basic','Intermediate','Advanced','Expert') NOT NULL DEFAULT 'Intermediate',
  `match_weight` decimal(5,2) NOT NULL DEFAULT 100.00,
  `is_primary` tinyint(1) NOT NULL DEFAULT 0,
  `active` tinyint(1) NOT NULL DEFAULT 1
) ;

--
-- Dumping data for table `category_skill_mappings`
--

INSERT INTO `category_skill_mappings` (`category_skill_mapping_id`, `category_id`, `skill_id`, `required_level`, `match_weight`, `is_primary`, `active`) VALUES
(1, 1, 1, 'Advanced', 100.00, 1, 1),
(2, 2, 2, 'Intermediate', 100.00, 1, 1),
(3, 3, 3, 'Advanced', 100.00, 1, 1),
(4, 4, 4, 'Intermediate', 100.00, 1, 1),
(5, 5, 2, 'Intermediate', 90.00, 1, 1),
(6, 6, 5, 'Basic', 100.00, 1, 1),
(7, 7, 6, 'Intermediate', 100.00, 1, 1),
(8, 8, 7, 'Intermediate', 100.00, 1, 1),
(9, 9, 8, 'Intermediate', 100.00, 1, 1),
(10, 10, 9, 'Advanced', 100.00, 1, 1),
(11, 11, 10, 'Advanced', 100.00, 1, 1),
(12, 12, 11, 'Advanced', 100.00, 1, 1),
(13, 13, 12, 'Intermediate', 100.00, 1, 1),
(14, 10, 1, 'Advanced', 70.00, 0, 1),
(15, 13, 7, 'Intermediate', 60.00, 0, 1);

-- --------------------------------------------------------

--
-- Table structure for table `duplicate_matches`
--

CREATE TABLE `duplicate_matches` (
  `duplicate_match_id` bigint(20) UNSIGNED NOT NULL,
  `source_ticket_id` bigint(20) UNSIGNED NOT NULL,
  `matched_ticket_id` bigint(20) UNSIGNED NOT NULL,
  `similarity_score` decimal(6,5) NOT NULL,
  `location_match_score` decimal(6,5) DEFAULT NULL,
  `match_status` enum('Pending','Confirmed','Rejected','Linked') NOT NULL DEFAULT 'Pending',
  `reviewed_by` bigint(20) UNSIGNED DEFAULT NULL,
  `review_notes` varchar(1000) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `reviewed_at` datetime DEFAULT NULL
) ;

--
-- Dumping data for table `duplicate_matches`
--

INSERT INTO `duplicate_matches` (`duplicate_match_id`, `source_ticket_id`, `matched_ticket_id`, `similarity_score`, `location_match_score`, `match_status`, `reviewed_by`, `review_notes`, `created_at`, `reviewed_at`) VALUES
(1, 135, 134, 0.92000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-24 09:28:02', NULL),
(2, 137, 136, 0.94000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-24 11:54:02', NULL),
(3, 139, 138, 0.91000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-24 14:20:02', NULL),
(4, 148, 147, 0.95000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-25 01:17:02', NULL),
(5, 150, 149, 0.92000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-25 03:43:02', NULL),
(6, 152, 151, 0.94000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-25 06:09:02', NULL),
(7, 160, 159, 0.92000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-25 15:53:02', NULL),
(8, 162, 161, 0.94000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-25 18:19:02', NULL),
(9, 164, 163, 0.91000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-25 20:45:02', NULL),
(10, 173, 172, 0.95000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-26 07:42:02', NULL),
(11, 175, 174, 0.92000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-26 10:08:02', NULL),
(12, 177, 176, 0.94000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-26 12:34:02', NULL),
(13, 184, 183, 0.91000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-26 21:05:02', NULL),
(14, 186, 185, 0.93000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-26 23:31:02', NULL),
(15, 188, 187, 0.95000, 1.00000, 'Pending', NULL, 'Same building, same reported floor and semantically equivalent maintenance issue.', '2026-08-27 01:57:02', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `floors`
--

CREATE TABLE `floors` (
  `floor_id` bigint(20) UNSIGNED NOT NULL,
  `building_id` bigint(20) UNSIGNED NOT NULL,
  `floor_number` smallint(6) NOT NULL,
  `name` varchar(80) NOT NULL,
  `status` enum('Active','Inactive') NOT NULL DEFAULT 'Active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `floors`
--

INSERT INTO `floors` (`floor_id`, `building_id`, `floor_number`, `name`, `status`, `created_at`, `updated_at`) VALUES
(1, 1, 0, 'Ground Floor', 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(2, 1, 5, '5th Floor', 'Active', '2026-08-15 13:50:19', '2026-08-17 13:36:22'),
(3, 2, 0, 'Ground Floor', 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(4, 2, 3, '3rd Floor', 'Active', '2026-08-15 13:50:19', '2026-08-17 13:36:22'),
(5, 3, -1, 'Basement', 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(6, 3, 0, 'Ground Floor', 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(7, 3, 8, '8th Floor', 'Active', '2026-08-15 13:50:19', '2026-08-17 13:36:22'),
(8, 1, 1, '1st Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(9, 2, 1, '1st Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(10, 3, 1, '1st Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(11, 1, 2, '2nd Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(12, 2, 2, '2nd Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(13, 3, 2, '2nd Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(14, 1, 3, '3rd Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(15, 3, 3, '3rd Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(16, 1, 4, '4th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(17, 2, 4, '4th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(18, 3, 4, '4th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(19, 2, 5, '5th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(20, 3, 5, '5th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(21, 1, 6, '6th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(22, 2, 6, '6th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(23, 3, 6, '6th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(24, 1, 7, '7th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(25, 2, 7, '7th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(26, 3, 7, '7th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(27, 1, 8, '8th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(28, 2, 8, '8th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(29, 1, 9, '9th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(30, 2, 9, '9th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(31, 3, 9, '9th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(32, 1, 10, '10th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(33, 2, 10, '10th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(34, 3, 10, '10th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(35, 1, 11, '11th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(36, 2, 11, '11th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(37, 3, 11, '11th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(38, 1, 12, '12th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(39, 2, 12, '12th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(40, 3, 12, '12th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(41, 1, 13, '13th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(42, 2, 13, '13th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(43, 3, 13, '13th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(44, 1, 14, '14th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(45, 2, 14, '14th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(46, 3, 14, '14th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(47, 1, 15, '15th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(48, 2, 15, '15th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(49, 3, 15, '15th Floor', 'Active', '2026-08-17 13:36:22', '2026-08-17 13:36:22'),
(50, 1, 16, '16th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(51, 3, 16, '16th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(52, 4, 1, '1st Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(53, 4, 2, '2nd Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(54, 4, 3, '3rd Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(55, 4, 4, '4th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(56, 4, 5, '5th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(57, 4, 6, '6th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(58, 4, 7, '7th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(59, 4, 8, '8th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(60, 4, 9, '9th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(61, 4, 10, '10th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(62, 7, 1, '1st Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(63, 7, 2, '2nd Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(64, 7, 3, '3rd Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(65, 7, 4, '4th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(66, 7, 5, '5th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(67, 7, 6, '6th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(68, 7, 7, '7th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(69, 7, 8, '8th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(70, 7, 9, '9th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(71, 7, 10, '10th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00'),
(72, 7, 11, '11th Floor', 'Active', '2026-08-17 12:30:00', '2026-08-17 12:30:00');

-- --------------------------------------------------------

--
-- Table structure for table `issue_categories`
--

CREATE TABLE `issue_categories` (
  `category_id` bigint(20) UNSIGNED NOT NULL,
  `category_code` varchar(50) NOT NULL,
  `name` varchar(100) NOT NULL,
  `default_skill_id` bigint(20) UNSIGNED DEFAULT NULL,
  `default_priority` enum('Emergency','High','Medium','Low') NOT NULL DEFAULT 'Medium',
  `severity_weight` decimal(5,2) NOT NULL DEFAULT 0.00,
  `description` varchar(255) DEFAULT NULL,
  `active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ;

--
-- Dumping data for table `issue_categories`
--

INSERT INTO `issue_categories` (`category_id`, `category_code`, `name`, `default_skill_id`, `default_priority`, `severity_weight`, `description`, `active`, `created_at`, `updated_at`) VALUES
(1, 'ELEC', 'Electrical', 1, 'High', 20.00, 'Electrical faults and power issues', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(2, 'PLUMB', 'Plumbing', 2, 'Medium', 12.00, 'Water leaks and plumbing issues', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(3, 'LIFT', 'Lift', 3, 'High', 22.00, 'Lift and elevator faults', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(4, 'AC', 'Air Conditioning', 4, 'Medium', 8.00, 'Air conditioning and ventilation faults', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(5, 'DRAIN', 'Drainage', 2, 'High', 15.00, 'Drainage and sewage problems', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(6, 'CLEAN', 'Cleaning', 5, 'Low', 4.00, 'Cleaning and common area issues', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(7, 'PEST', 'Pest Control', 6, 'Low', 7.00, 'Pest and insect control issues', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(8, 'CARP', 'Carpentry', 7, 'Low', 5.00, 'Doors, windows, fittings and carpentry work', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(9, 'OTHER', 'Other', 8, 'Medium', 5.00, 'Other general building maintenance issues', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(10, 'FIRE', 'Fire and Safety', 9, 'Emergency', 30.00, 'Fire, smoke, alarm and immediate safety incidents', 1, '2026-08-17 11:54:53', '2026-08-17 11:54:53'),
(11, 'GAS', 'Gas', 10, 'Emergency', 30.00, 'Gas smell, leakage and gas safety issues', 1, '2026-08-17 11:54:53', '2026-08-17 11:54:53'),
(12, 'STRUCT', 'Structural', 11, 'High', 25.00, 'Walls, ceilings, roofs, cracks and structural damage', 1, '2026-08-17 11:54:53', '2026-08-17 11:54:53'),
(13, 'SEC', 'Security and Access', 12, 'High', 18.00, 'Security doors, access control, gates and locks', 1, '2026-08-17 11:54:53', '2026-08-17 11:54:53');

-- --------------------------------------------------------

--
-- Table structure for table `login_attempts`
--

CREATE TABLE `login_attempts` (
  `login_attempt_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED DEFAULT NULL,
  `email_entered` varchar(190) DEFAULT NULL,
  `was_successful` tinyint(1) NOT NULL,
  `ip_address` varchar(45) DEFAULT NULL,
  `user_agent` varchar(500) DEFAULT NULL,
  `failure_reason` varchar(255) DEFAULT NULL,
  `attempted_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `login_attempts`
--

INSERT INTO `login_attempts` (`login_attempt_id`, `user_id`, `email_entered`, `was_successful`, `ip_address`, `user_agent`, `failure_reason`, `attempted_at`) VALUES
(16, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-24 01:01:19'),
(17, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-24 01:07:18'),
(18, 297, 'nethmi.perera@outlook.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-24 01:19:43'),
(19, 405, 'tech@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-24 01:20:08'),
(20, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-24 23:02:52'),
(21, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-24 23:03:45'),
(22, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 01:35:56'),
(23, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 01:36:27'),
(24, 297, 'nethmi.perera@outlook.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 01:49:55'),
(25, 405, 'tech@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 01:50:41'),
(26, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 13:52:13'),
(27, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 14:48:17'),
(28, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 14:49:04'),
(29, 405, 'tech@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 14:50:09'),
(30, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 17:25:32'),
(31, 481, 'ravini.gunasekara.sys@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 17:27:17'),
(32, 373, 'jayantha.fernando.lift@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 17:28:20'),
(33, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 17:28:53'),
(34, 342, 'sachini.de.silva@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 17:29:30'),
(35, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 17:30:27'),
(36, 344, 'tharushi.gunawardena@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:29:09'),
(37, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:38:34'),
(38, 300, 'sandun.jayasekara@icloud.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:39:12'),
(39, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:45:08'),
(40, 340, 'iresha.jayasinghe@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:45:33'),
(41, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:46:21'),
(42, 336, 'chathurika.senanayake@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:46:46'),
(43, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:47:00'),
(44, 339, 'harini.wijesinghe@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:47:26'),
(45, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:47:45'),
(46, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:48:08'),
(47, 300, 'sandun.jayasekara@icloud.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:54:38'),
(48, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:55:00'),
(49, 300, 'sandun.jayasekara@icloud.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:55:34'),
(50, 15, 'rakindufernando@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-26 18:56:00'),
(51, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:56:16'),
(52, 336, 'chathurika.senanayake@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:56:35'),
(53, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:58:18'),
(54, 369, 'indika.jayawardena.drain@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:58:40'),
(55, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:59:33'),
(56, 300, 'sandun.jayasekara@icloud.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 18:59:53'),
(57, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 20:41:42'),
(58, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 20:43:49'),
(59, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 20:47:13'),
(60, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 20:47:54'),
(61, 405, 'tech@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 20:49:20'),
(62, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 23:53:25'),
(63, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 23:57:03'),
(64, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 00:40:05'),
(65, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 01:18:15'),
(66, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 01:18:54'),
(67, 297, 'nethmi.perera@outlook.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 01:21:10'),
(68, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 01:21:33'),
(69, 297, 'nethmi.perera@outlook.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Invalid password', '2026-08-27 01:46:34'),
(70, 297, 'nethmi.perera@outlook.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 01:46:46'),
(71, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 01:50:14'),
(72, 305, 'tharushi.perera@outlook.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 02:02:04'),
(73, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 02:13:42'),
(74, 305, 'tharushi.perera@outlook.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 02:17:37'),
(75, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 02:24:21'),
(76, 305, 'tharushi.perera@outlook.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 02:29:01'),
(77, 272, 'akila.dissanayake@gmail.com', 1, '192.168.10.92', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 16:44:00'),
(78, 273, 'amanda.perera@outlook.com', 1, '192.168.10.93', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 17:21:00'),
(79, 274, 'anjali.herath@hotmail.com', 1, '192.168.10.94', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-26 17:58:00'),
(80, 275, 'chamod.wickramasinghe@yahoo.com', 1, '192.168.10.95', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 18:35:00'),
(81, 276, 'dhanushka.gunawardena@icloud.com', 1, '192.168.10.96', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 19:12:00'),
(82, 277, 'dinithi.jayawardena@live.com', 1, '192.168.10.97', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-26 19:49:00'),
(83, 278, 'dulanjali.desilva@proton.me', 1, '192.168.10.98', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 20:26:00'),
(84, 279, 'gimhani.silva@msn.com', 1, '192.168.10.99', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 21:03:00'),
(85, 280, 'hasini.fernando@gmail.com', 1, '192.168.10.100', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-26 21:40:00'),
(86, 281, 'hiruni.samarasinghe@outlook.com', 1, '192.168.10.101', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 22:17:00'),
(87, 282, 'imesha.karunaratne@hotmail.com', 1, '192.168.10.102', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 22:54:00'),
(88, 283, 'ishadi.fernando@yahoo.com', 1, '192.168.10.103', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-23 08:31:00'),
(89, 284, 'janith.ekanayake@icloud.com', 1, '192.168.10.104', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-23 09:08:00'),
(90, 285, 'kavindu.silva@live.com', 1, '192.168.10.105', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-23 09:45:00'),
(91, 286, 'kusal.mendis@proton.me', 1, '192.168.10.106', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-23 10:22:00'),
(92, 287, 'lahiru.dilshan@msn.com', 1, '192.168.10.107', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-23 10:59:00'),
(93, 288, 'malith.senanayake@gmail.com', 1, '192.168.10.108', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-23 11:36:00'),
(94, 289, 'manori.senanayake@outlook.com', 1, '192.168.10.109', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-23 12:13:00'),
(95, 290, 'nadeesha.priyadarshani@hotmail.com', 1, '192.168.10.110', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-23 12:50:00'),
(96, 291, 'nimesh.wijesinghe@yahoo.com', 1, '192.168.10.111', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-23 13:27:00'),
(97, 292, 'oshadi.gunasekara@icloud.com', 1, '192.168.10.112', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-23 14:04:00'),
(98, 293, 'pabasara.wijekoon@live.com', 1, '192.168.10.113', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-23 14:41:00'),
(99, 294, 'pasindu.bandara@proton.me', 1, '192.168.10.114', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-23 15:18:00'),
(100, 295, 'piumi.rathnayake@msn.com', 1, '192.168.10.115', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-23 15:55:00'),
(101, 296, 'ravindu.lakshan@gmail.com', 1, '192.168.10.116', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-23 16:32:00'),
(102, 298, 'rukshan.fernando@hotmail.com', 1, '192.168.10.118', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-23 17:46:00'),
(103, 299, 'sachini.weerasinghe@yahoo.com', 1, '192.168.10.119', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-23 18:23:00'),
(104, 301, 'sewwandi.kumari@live.com', 1, '192.168.10.121', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-23 19:37:00'),
(105, 302, 'shashika.madurangi@proton.me', 1, '192.168.10.122', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-23 20:14:00'),
(106, 303, 'shehan.peiris@msn.com', 1, '192.168.10.123', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-23 20:51:00'),
(107, 304, 'supun.niroshan@gmail.com', 1, '192.168.10.124', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-23 21:28:00'),
(108, 306, 'thilini.abeysekara@hotmail.com', 1, '192.168.10.126', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-23 22:42:00'),
(109, 307, 'thiwanka.samarakoon@yahoo.com', 1, '192.168.10.127', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-23 23:19:00'),
(110, 308, 'upeksha.madushani@icloud.com', 1, '192.168.10.128', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-23 23:56:00'),
(111, 309, 'vihanga.rajapaksha@live.com', 1, '192.168.10.129', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-24 00:33:00'),
(112, 337, 'dinusha.karunaratne@helafixit.lk', 1, '192.168.20.157', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-24 17:49:00'),
(113, 338, 'gayani.rathnayake@helafixit.lk', 1, '192.168.20.158', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-24 18:26:00'),
(114, 341, 'nadeesha.perera@helafixit.lk', 1, '192.168.20.161', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-24 20:17:00'),
(115, 343, 'shalini.abeysekera@helafixit.lk', 1, '192.168.20.163', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-24 21:31:00'),
(116, 350, 'amila.perera.elec@helafixit.lk', 1, '192.168.30.170', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 01:50:00'),
(117, 351, 'asanka.weerasinghe.other@helafixit.lk', 1, '192.168.30.171', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 02:27:00'),
(118, 352, 'ashan.senanayake.pest@helafixit.lk', 1, '192.168.30.172', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 03:04:00'),
(119, 353, 'bimal.rathnayake.carp@helafixit.lk', 1, '192.168.30.173', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 03:41:00'),
(120, 354, 'buddhika.silva.plumb@helafixit.lk', 1, '192.168.30.174', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 04:18:00'),
(121, 355, 'chamara.perera.plumb@helafixit.lk', 1, '192.168.30.175', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 04:55:00'),
(122, 356, 'chamil.fernando.lift@helafixit.lk', 1, '192.168.30.176', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 05:32:00'),
(123, 357, 'charith.peiris.other@helafixit.lk', 1, '192.168.30.177', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 06:09:00'),
(124, 358, 'chathura.bandara.ac@helafixit.lk', 1, '192.168.30.178', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 06:46:00'),
(125, 359, 'damith.dissanayake.gas@helafixit.lk', 1, '192.168.30.179', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 07:23:00'),
(126, 360, 'darshana.herath.fire@helafixit.lk', 1, '192.168.30.180', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 08:00:00'),
(127, 361, 'dinesh.fernando.ac@helafixit.lk', 1, '192.168.30.181', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 08:37:00'),
(128, 362, 'eranga.wijekoon.struct@helafixit.lk', 1, '192.168.30.182', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 09:14:00'),
(129, 363, 'eshan.dissanayake.gas@helafixit.lk', 1, '192.168.30.183', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 09:51:00'),
(130, 364, 'fairooz.ahamed.struct@helafixit.lk', 1, '192.168.30.184', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 10:28:00'),
(131, 365, 'gayan.perera.elec@helafixit.lk', 1, '192.168.30.185', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 11:05:00'),
(132, 366, 'gihan.samarasinghe.sec@helafixit.lk', 1, '192.168.30.186', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 11:42:00'),
(133, 367, 'harsha.bandara.ac@helafixit.lk', 1, '192.168.30.187', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 12:19:00'),
(134, 368, 'heshan.perera.elec@helafixit.lk', 1, '192.168.30.188', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 12:56:00'),
(135, 370, 'ishan.silva.plumb@helafixit.lk', 1, '192.168.30.190', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 14:10:00'),
(136, 371, 'isuru.madushan.drain@helafixit.lk', 1, '192.168.30.191', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 14:47:00'),
(137, 372, 'janaka.rathnayake.carp@helafixit.lk', 1, '192.168.30.192', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 15:24:00'),
(138, 374, 'jeewan.gunawardena.clean@helafixit.lk', 1, '192.168.30.194', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 16:38:00'),
(139, 375, 'kanishka.samarasinghe.sec@helafixit.lk', 1, '192.168.30.195', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 17:15:00'),
(140, 376, 'kasun.maduranga.sec@helafixit.lk', 1, '192.168.30.196', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 17:52:00'),
(141, 377, 'kaveen.bandara.ac@helafixit.lk', 1, '192.168.30.197', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 18:29:00'),
(142, 378, 'kelum.senanayake.pest@helafixit.lk', 1, '192.168.30.198', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 19:06:00'),
(143, 379, 'lahiru.senanayake.pest@helafixit.lk', 1, '192.168.30.199', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 19:43:00'),
(144, 380, 'lakmal.rathnayake.carp@helafixit.lk', 1, '192.168.30.200', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 20:20:00'),
(145, 381, 'lasantha.jayawardena.drain@helafixit.lk', 1, '192.168.30.201', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 20:57:00'),
(146, 382, 'madhuka.senanayake.pest@helafixit.lk', 1, '192.168.30.202', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 21:34:00'),
(147, 383, 'mahesh.karunaratne.gas@helafixit.lk', 1, '192.168.30.203', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 22:11:00'),
(148, 384, 'malinga.gunawardena.clean@helafixit.lk', 1, '192.168.30.204', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 22:48:00'),
(149, 385, 'manjula.herath.fire@helafixit.lk', 1, '192.168.30.205', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 23:25:00'),
(150, 386, 'milan.peiris.other@helafixit.lk', 1, '192.168.30.206', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 00:02:00'),
(151, 387, 'nalaka.herath.fire@helafixit.lk', 1, '192.168.30.207', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 00:39:00'),
(152, 388, 'naveen.senanayake.pest@helafixit.lk', 1, '192.168.30.208', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-26 01:16:00'),
(153, 389, 'osanda.rathnayake.carp@helafixit.lk', 1, '192.168.30.209', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 01:53:00'),
(154, 390, 'oshan.dissanayake.gas@helafixit.lk', 1, '192.168.30.210', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 02:30:00'),
(155, 391, 'prabath.wijekoon.struct@helafixit.lk', 1, '192.168.30.211', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-26 03:07:00'),
(156, 392, 'pradeep.rajapaksha.fire@helafixit.lk', 1, '192.168.30.212', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 03:44:00'),
(157, 393, 'pubudu.peiris.other@helafixit.lk', 1, '192.168.30.213', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 04:21:00'),
(158, 394, 'ranga.samarasinghe.sec@helafixit.lk', 1, '192.168.30.214', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-26 04:58:00'),
(159, 395, 'ravimal.herath.fire@helafixit.lk', 1, '192.168.30.215', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 05:35:00'),
(160, 396, 'roshan.fernando.lift@helafixit.lk', 1, '192.168.30.216', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 06:12:00'),
(161, 397, 'ruwan.bandara.carp@helafixit.lk', 1, '192.168.30.217', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-26 06:49:00'),
(162, 398, 'sachith.de.silva.struct@helafixit.lk', 1, '192.168.30.218', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 07:26:00'),
(163, 399, 'sahan.silva.plumb@helafixit.lk', 1, '192.168.30.219', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 08:03:00'),
(164, 400, 'sajith.dissanayake.gas@helafixit.lk', 1, '192.168.30.20', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-26 08:40:00'),
(165, 401, 'sameera.gunasekara.clean@helafixit.lk', 1, '192.168.30.21', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 09:17:00'),
(166, 402, 'sampath.perera.elec@helafixit.lk', 1, '192.168.30.22', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 09:54:00'),
(167, 403, 'sanjaya.peiris.other@helafixit.lk', 1, '192.168.30.23', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-26 10:31:00'),
(168, 404, 'supun.jayasinghe.lift@helafixit.lk', 1, '192.168.30.24', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 11:08:00'),
(169, 406, 'tharanga.wijekoon.struct@helafixit.lk', 1, '192.168.30.26', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-26 12:22:00'),
(170, 407, 'tharindu.kumara.clean@helafixit.lk', 1, '192.168.30.27', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 12:59:00'),
(171, 408, 'thilak.silva.plumb@helafixit.lk', 1, '192.168.30.28', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 13:36:00'),
(172, 409, 'udara.jayasinghe.drain@helafixit.lk', 1, '192.168.30.29', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-26 14:13:00'),
(173, 410, 'udaya.samarasinghe.sec@helafixit.lk', 1, '192.168.30.30', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 14:50:00'),
(174, 411, 'upul.fernando.lift@helafixit.lk', 1, '192.168.30.31', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 15:27:00'),
(175, 412, 'vajira.bandara.ac@helafixit.lk', 1, '192.168.30.32', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-26 16:04:00'),
(176, 413, 'wasantha.jayawardena.drain@helafixit.lk', 1, '192.168.30.33', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-26 16:41:00'),
(177, 414, 'yohan.gunawardena.clean@helafixit.lk', 1, '192.168.30.34', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-26 17:18:00'),
(178, 477, 'dulanjana.silva.sys@helafixit.lk', 1, '192.168.40.97', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-24 17:09:00'),
(179, 478, 'hasini.wickramasinghe.sys@helafixit.lk', 1, '192.168.40.98', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-24 17:46:00'),
(180, 479, 'malith.jayawardena.sys@helafixit.lk', 1, '192.168.40.99', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-24 18:23:00'),
(181, 480, 'nipuni.fernando.sys@helafixit.lk', 1, '192.168.40.100', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-24 19:00:00'),
(182, 482, 'sadmin@helafixit.lk', 1, '192.168.40.102', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-24 20:14:00'),
(183, 483, 'sajith.bandara.sys@helafixit.lk', 1, '192.168.40.103', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-24 20:51:00'),
(184, 484, 'tharushi.senanayake@proton.me', 1, '192.168.10.104', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-24 21:28:00'),
(185, 485, 'pasindu.madushanka@msn.com', 1, '192.168.10.105', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-24 22:05:00'),
(186, 486, 'oshadi.wijesinghe@gmail.com', 1, '192.168.10.106', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-24 22:42:00'),
(187, 487, 'sahan.jayalath@outlook.com', 1, '192.168.10.107', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-24 23:19:00'),
(188, 488, 'navodya.bandara@hotmail.com', 1, '192.168.10.108', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-24 23:56:00'),
(189, 489, 'kaveesha.rathnayake@yahoo.com', 1, '192.168.10.109', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 00:33:00'),
(190, 490, 'thisara.abeysekara@icloud.com', 1, '192.168.10.110', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 01:10:00'),
(191, 491, 'chathuni.gamage@live.com', 1, '192.168.10.111', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 01:47:00'),
(192, 492, 'duleeka.ranasinghe@proton.me', 1, '192.168.10.112', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 02:24:00'),
(193, 493, 'sachin.fernando@msn.com', 1, '192.168.10.113', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 03:01:00'),
(194, 494, 'nimesha.weerasinghe@gmail.com', 1, '192.168.10.114', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 03:38:00'),
(195, 495, 'lasith.perera@outlook.com', 1, '192.168.10.115', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 04:15:00'),
(196, 496, 'piumi.gunasekara@hotmail.com', 1, '192.168.10.116', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 04:52:00'),
(197, 497, 'ravindu.pathirana@yahoo.com', 1, '192.168.10.117', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 05:29:00'),
(198, 498, 'himashi.wickramanayake@icloud.com', 1, '192.168.10.118', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 06:06:00'),
(199, 499, 'kavisha.maduranga@live.com', 1, '192.168.10.119', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 06:43:00'),
(200, 500, 'senuri.dealwis@proton.me', 1, '192.168.10.120', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 07:20:00'),
(201, 501, 'ashen.rodrigo@msn.com', 1, '192.168.10.121', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 07:57:00'),
(202, 502, 'thilini.edirisinghe@gmail.com', 1, '192.168.10.122', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 08:34:00'),
(203, 503, 'malith.peiris@outlook.com', 1, '192.168.10.123', 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36', NULL, '2026-08-25 09:11:00'),
(204, 504, 'vihanga.samarawickrama@hotmail.com', 1, '192.168.10.124', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-25 09:48:00'),
(205, 505, 'dinuka.nawaratne@yahoo.com', 1, '192.168.10.125', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0', NULL, '2026-08-25 10:25:00'),
(332, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 03:16:01'),
(333, 15, 'rakindufernando@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-27 03:18:31'),
(334, 498, 'himashi.wickramanayake@icloud.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 03:18:38'),
(335, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 03:19:12'),
(336, 279, 'gimhani.silva@msn.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 03:19:41'),
(337, 279, 'gimhani.silva@msn.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 03:20:21'),
(338, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 12:29:16'),
(339, 15, 'rakindufernando@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-27 12:29:16'),
(340, 15, 'rakindufernando@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-27 12:29:16'),
(341, 15, 'rakindufernando@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-27 12:29:16'),
(342, 15, 'rakindufernando@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-27 12:29:16'),
(343, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 12:29:46'),
(344, 15, 'rakindufernando@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-27 12:29:46'),
(345, 15, 'rakindufernando@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-27 12:29:46'),
(346, 15, 'rakindufernando@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-27 12:29:46'),
(347, 15, 'rakindufernando@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-27 12:30:21'),
(348, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 12:30:37'),
(349, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 12:30:37'),
(350, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 12:39:25'),
(351, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 12:39:40'),
(352, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 12:43:06'),
(353, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 12:53:50'),
(354, 405, 'tech@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 12:55:13'),
(355, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 12:56:01'),
(356, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 12:56:48'),
(357, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 13:12:07'),
(358, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 13:14:20'),
(359, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 13:46:30'),
(360, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:08:16'),
(361, 298, 'rukshan.fernando@hotmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:08:58'),
(362, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:09:21'),
(363, 505, 'dinuka.nawaratne@yahoo.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:10:00'),
(364, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:10:16'),
(365, 343, 'shalini.abeysekera@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:10:39'),
(366, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:11:09'),
(367, 342, 'sachini.de.silva@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:11:30'),
(368, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:12:22'),
(369, 344, 'tharushi.gunawardena@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:12:47'),
(370, NULL, 'resident@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Account not found', '2026-08-27 14:19:40'),
(371, NULL, 'resident@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Account not found', '2026-08-27 14:19:48'),
(372, NULL, 'resident@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Account not found', '2026-08-27 14:20:16'),
(373, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:20:25'),
(374, 297, 'nethmi.perera@outlook.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:25:47'),
(375, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 14:26:26'),
(376, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 16:37:07'),
(377, 405, 'tech@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-27 17:27:55'),
(378, 405, 'tech@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 10:23:53'),
(379, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 10:24:34'),
(380, 277, 'dinithi.jayawardena@live.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 10:24:58'),
(381, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 10:31:31'),
(382, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 10:31:50');
INSERT INTO `login_attempts` (`login_attempt_id`, `user_id`, `email_entered`, `was_successful`, `ip_address`, `user_agent`, `failure_reason`, `attempted_at`) VALUES
(383, 15, 'rakindufernando@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-29 10:33:30'),
(384, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 10:33:33'),
(385, 371, 'isuru.madushan.drain@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 10:33:52'),
(386, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 10:40:34'),
(387, 498, 'himashi.wickramanayake@icloud.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 10:40:55'),
(388, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 10:49:20'),
(389, 301, 'sewwandi.kumari@live.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 10:50:39'),
(390, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 11:08:57'),
(391, 337, 'dinusha.karunaratne@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 11:09:22'),
(392, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 11:10:07'),
(393, 402, 'sampath.perera.elec@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 11:10:29'),
(394, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 12:24:56'),
(395, 504, 'vihanga.samarawickrama@hotmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 12:25:24'),
(396, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 12:26:12'),
(397, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 12:34:36'),
(398, 505, 'dinuka.nawaratne@yahoo.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 12:35:54'),
(399, 505, 'dinuka.nawaratne@yahoo.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 12:35:55'),
(400, 505, 'dinuka.nawaratne@yahoo.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 12:36:23'),
(401, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 12:36:36'),
(402, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 13:39:22'),
(403, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 13:41:43'),
(404, 342, 'sachini.de.silva@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 13:42:07'),
(405, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 13:45:34'),
(406, 393, 'pubudu.peiris.other@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 13:45:54'),
(407, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 13:53:53'),
(408, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-29 14:07:41'),
(409, 341, 'nadeesha.perera@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-29 14:10:23'),
(410, 507, 'nirmalfernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-29 14:11:06'),
(411, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-29 14:12:00'),
(412, 405, 'tech@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 14:57:49'),
(413, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 14:58:12'),
(414, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 18:32:42'),
(415, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Invalid password', '2026-08-29 18:35:48'),
(416, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Invalid password', '2026-08-29 18:35:54'),
(417, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Invalid password', '2026-08-29 18:36:05'),
(418, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-29 18:36:07'),
(419, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-29 18:36:10'),
(420, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-29 18:36:12'),
(421, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Invalid password', '2026-08-29 18:36:19'),
(422, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 18:36:26'),
(423, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Invalid password. Account locked for 15 minutes.', '2026-08-29 18:36:53'),
(424, 15, 'rakindufernando@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-29 18:36:57'),
(425, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 18:37:00'),
(426, 506, 'savindi.perera26@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 18:38:06'),
(427, 506, 'savindi.perera26@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 18:38:34'),
(428, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Invalid password', '2026-08-29 18:39:01'),
(429, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Invalid password', '2026-08-29 18:39:05'),
(430, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Invalid password', '2026-08-29 18:39:07'),
(431, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Invalid password', '2026-08-29 18:39:07'),
(432, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Invalid password. Account locked for 15 minutes.', '2026-08-29 18:39:08'),
(433, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account temporarily locked', '2026-08-29 18:39:08'),
(434, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account temporarily locked', '2026-08-29 18:39:08'),
(435, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 18:39:21'),
(436, 480, 'nipuni.fernando.sys@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 18:40:03'),
(437, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 18:40:57'),
(438, NULL, 'sandun.jayasekara@resident.helafixit.lk', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account not found', '2026-08-29 18:46:51'),
(439, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 18:46:59'),
(440, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:25'),
(441, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:30'),
(442, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:31'),
(443, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:31'),
(444, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:31'),
(445, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:31'),
(446, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:31'),
(447, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:31'),
(448, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:31'),
(449, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:32'),
(450, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:32'),
(451, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:32'),
(452, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:32'),
(453, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:32'),
(454, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:32'),
(455, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:32'),
(456, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:33'),
(457, 506, 'savindi.perera26@gmail.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Account status Suspended', '2026-08-29 18:47:33'),
(458, 405, 'tech@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 18:48:11'),
(459, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 20:09:07'),
(460, 499, 'kavisha.maduranga@live.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-29 20:09:30'),
(461, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:14:49'),
(462, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:17:13'),
(463, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:17:48'),
(464, 273, 'amanda.perera@outlook.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:21:07'),
(465, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:21:31'),
(466, 277, 'dinithi.jayawardena@live.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:22:16'),
(467, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:28:19'),
(468, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:30:51'),
(469, 501, 'ashen.rodrigo@msn.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:31:30'),
(470, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:37:40'),
(471, 337, 'dinusha.karunaratne@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:38:22'),
(472, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:39:12'),
(473, 402, 'sampath.perera.elec@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:39:35'),
(474, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:50:23'),
(475, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:57:22'),
(476, 402, 'sampath.perera.elec@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 00:58:08'),
(477, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 01:07:56'),
(478, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 01:08:37'),
(479, 505, 'dinuka.nawaratne@yahoo.com', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Invalid password', '2026-08-30 01:19:14'),
(480, 306, 'thilini.abeysekara@hotmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 01:19:45'),
(481, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 01:21:50'),
(482, 306, 'thilini.abeysekara@hotmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Temporary password login', '2026-08-30 01:43:11'),
(483, 306, 'thilini.abeysekara@hotmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 01:44:03'),
(484, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 01:51:37'),
(485, 339, 'harini.wijesinghe@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 01:52:02'),
(486, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 01:52:46'),
(487, 365, 'gayan.perera.elec@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 01:53:20'),
(488, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 01:55:54'),
(489, 344, 'tharushi.gunawardena@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 01:56:21'),
(490, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 04:06:33'),
(491, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 04:06:53'),
(492, 483, 'sajith.bandara.sys@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 04:07:14'),
(493, 483, 'sajith.bandara.sys@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 04:08:20'),
(494, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 08:44:26'),
(495, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 08:45:19'),
(496, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:01:45'),
(497, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:04:04'),
(498, 481, 'ravini.gunasekara.sys@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:05:01'),
(499, 481, 'ravini.gunasekara.sys@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:05:48'),
(500, 505, 'dinuka.nawaratne@yahoo.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', 'Temporary password login', '2026-08-30 10:06:40'),
(501, 505, 'dinuka.nawaratne@yahoo.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:07:19'),
(502, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:14:06'),
(503, 338, 'gayani.rathnayake@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:14:33'),
(504, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:16:01'),
(505, 410, 'udaya.samarasinghe.sec@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:16:21'),
(506, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:18:29'),
(507, 307, 'thiwanka.samarakoon@yahoo.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:18:54'),
(508, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:22:20'),
(509, 338, 'gayani.rathnayake@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:22:45'),
(510, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:23:25'),
(511, 395, 'ravimal.herath.fire@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:23:47'),
(512, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 10:26:07'),
(513, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-30 13:37:44'),
(514, 507, 'nirmalfernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-30 13:38:34'),
(515, 335, 'admin@helafixit.lk', 0, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', 'Incorrect role selected', '2026-08-30 13:39:44'),
(516, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-30 13:39:50'),
(517, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-30 16:13:33'),
(518, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36', NULL, '2026-08-30 16:14:54'),
(519, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 16:15:25'),
(520, 342, 'sachini.de.silva@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 16:16:18'),
(521, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 16:26:05'),
(522, 496, 'piumi.gunasekara@hotmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 16:26:36'),
(523, 335, 'admin@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 16:27:17'),
(524, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 16:32:46'),
(525, 498, 'himashi.wickramanayake@icloud.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 16:33:06'),
(526, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 16:34:46'),
(527, 402, 'sampath.perera.elec@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-30 16:35:07'),
(528, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-31 00:28:46'),
(529, 501, 'ashen.rodrigo@msn.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-31 00:29:19'),
(530, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-31 00:29:56'),
(531, 402, 'sampath.perera.elec@helafixit.lk', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-31 00:30:13'),
(532, 15, 'rakindufernando@gmail.com', 1, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36', NULL, '2026-08-31 00:31:23');

-- --------------------------------------------------------

--
-- Table structure for table `maintenance_assets`
--

CREATE TABLE `maintenance_assets` (
  `asset_id` bigint(20) UNSIGNED NOT NULL,
  `building_id` bigint(20) UNSIGNED NOT NULL,
  `floor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `area_id` bigint(20) UNSIGNED DEFAULT NULL,
  `unit_id` bigint(20) UNSIGNED DEFAULT NULL,
  `category_id` bigint(20) UNSIGNED DEFAULT NULL,
  `asset_code` varchar(80) NOT NULL,
  `asset_type` varchar(100) NOT NULL,
  `name` varchar(150) NOT NULL,
  `status` enum('Active','Out of Service','Retired') NOT NULL DEFAULT 'Active',
  `notes` varchar(500) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `maintenance_tickets`
--

CREATE TABLE `maintenance_tickets` (
  `ticket_id` bigint(20) UNSIGNED NOT NULL,
  `ticket_number` varchar(40) NOT NULL,
  `resident_id` bigint(20) UNSIGNED NOT NULL,
  `building_id` bigint(20) UNSIGNED NOT NULL,
  `floor_id` bigint(20) UNSIGNED NOT NULL,
  `unit_id` bigint(20) UNSIGNED DEFAULT NULL,
  `area_id` bigint(20) UNSIGNED DEFAULT NULL,
  `asset_id` bigint(20) UNSIGNED DEFAULT NULL,
  `unit_number_snapshot` varchar(40) DEFAULT NULL,
  `subject` varchar(180) NOT NULL,
  `description` longtext NOT NULL,
  `language_type` enum('English','Sinhala','Singlish','Mixed','Unknown') NOT NULL DEFAULT 'Unknown',
  `asset_type` varchar(100) DEFAULT NULL,
  `contact_permission` tinyint(1) NOT NULL DEFAULT 0,
  `current_category_id` bigint(20) UNSIGNED DEFAULT NULL,
  `current_priority` enum('Emergency','High','Medium','Low') DEFAULT NULL,
  `current_risk_score` decimal(5,2) DEFAULT NULL,
  `current_risk_level` enum('Low','Medium','High','Critical') DEFAULT NULL,
  `current_status` enum('Submitted','Analysing','Awaiting Review','Urgent Unassigned','Auto Assigned','Assigned','Accepted','In Progress','On Hold','Resolved','Closed','Reopened','Cancelled') NOT NULL DEFAULT 'Submitted',
  `safety_flag` tinyint(1) NOT NULL DEFAULT 0,
  `duplicate_flag` tinyint(1) NOT NULL DEFAULT 0,
  `manual_review_required` tinyint(1) NOT NULL DEFAULT 0,
  `submitted_at` datetime NOT NULL DEFAULT current_timestamp(),
  `analysed_at` datetime DEFAULT NULL,
  `resolved_at` datetime DEFAULT NULL,
  `closed_at` datetime DEFAULT NULL,
  `cancelled_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ;

--
-- Dumping data for table `maintenance_tickets`
--

INSERT INTO `maintenance_tickets` (`ticket_id`, `ticket_number`, `resident_id`, `building_id`, `floor_id`, `unit_id`, `area_id`, `asset_id`, `unit_number_snapshot`, `subject`, `description`, `language_type`, `asset_type`, `contact_permission`, `current_category_id`, `current_priority`, `current_risk_score`, `current_risk_level`, `current_status`, `safety_flag`, `duplicate_flag`, `manual_review_required`, `submitted_at`, `analysed_at`, `resolved_at`, `closed_at`, `cancelled_at`, `created_at`, `updated_at`) VALUES
(65, 'TCK-HF-260823-A-REV01', 112, 1, 8, 29, 27, NULL, 'A-101', 'Bedroom door hinge is loose', 'The bedroom door hinge is loose and the door is difficult to close. Please check it.', 'English', 'Door', 1, 8, 'Low', 24.00, 'Low', 'Awaiting Review', 0, 0, 1, '2026-08-23 14:05:00', '2026-08-23 14:05:02', NULL, NULL, NULL, '2026-08-23 14:05:00', '2026-08-29 13:38:14'),
(66, 'TCK-HF-260823-A-UNA01', 100, 1, 11, 17, 72, NULL, 'A-202', 'Kitchen area gas smell', 'Kitchen eke gas smell ekak enawa. Valve eka langin smell eka wadi.', 'Singlish', 'Gas line', 1, 11, 'Emergency', 97.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 15:10:00', '2026-08-23 15:10:02', NULL, NULL, NULL, '2026-08-23 15:10:00', '2026-08-29 13:38:14'),
(67, 'TCK-HF-260823-A-ASG01', 92, 1, 14, 9, 24, NULL, 'A-303', 'Bathroom tap is leaking', 'Bathroom tap eka continuously leak wenawa. Water waste wenawa.', 'Singlish', 'Tap', 1, 2, 'Medium', 38.00, 'Medium', 'Assigned', 0, 0, 0, '2026-08-23 08:15:00', '2026-08-23 08:15:02', NULL, NULL, NULL, '2026-08-23 08:15:00', '2026-08-29 13:38:14'),
(68, 'TCK-HF-260822-A-PRG01', 95, 1, 16, 12, 81, NULL, 'A-404', 'Living room AC is not cooling', 'Living room AC eka on wenawa but cooling madi. Unusual sound ekakuth thiyenawa.', 'Mixed', 'Air conditioner', 1, 4, 'Medium', 44.00, 'Medium', 'In Progress', 0, 0, 0, '2026-08-22 14:20:00', '2026-08-22 14:20:02', NULL, NULL, NULL, '2026-08-22 14:20:00', '2026-08-29 13:38:14'),
(69, 'TCK-HF-260821-A-CMP01', 106, 1, 2, 23, NULL, NULL, 'A-505', 'ස්ටඩි ටේබල් අසල සොකට් එකෙන් ස්පාර්ක් වෙනවා', 'ස්ටඩි ටේබල් එක අසල බිත්ති සොකට් එකට ප්ලග් එකක් සම්බන්ධ කරන විට ස්පාර්ක් වෙනවා. කරුණාකර ඉක්මනින් සොකට් එක සහ වයරින් එක පරීක්ෂා කරන්න.', 'Sinhala', 'Power socket', 1, 1, 'High', 76.00, 'High', 'Resolved', 1, 0, 0, '2026-08-21 13:10:00', '2026-08-21 13:10:02', '2026-08-21 14:25:00', NULL, NULL, '2026-08-21 13:10:00', '2026-08-27 14:25:32'),
(70, 'TCK-HF-260823-B-REV01', 118, 2, 9, 35, 55, NULL, 'B-101', 'කසළ ප්‍රදේශය අසල කැරපොත්තන් පේනවා', 'සවස කාලයේ කසළ බැහැර කරන ප්‍රදේශය අසල කැරපොත්තන් කිහිපයක් පේනවා. කරුණාකර පළිබෝධ පාලන සේවාවක් සකස් කරන්න.', 'Sinhala', 'Garbage chute', 1, 7, 'Low', 27.00, 'Low', 'Awaiting Review', 0, 0, 1, '2026-08-23 14:15:00', '2026-08-23 14:15:02', NULL, NULL, NULL, '2026-08-23 14:15:00', '2026-08-29 13:38:14'),
(71, 'TCK-HF-260823-B-UNA01', 121, 2, 12, 38, NULL, NULL, 'B-202', 'Lift stopped between floors', 'Lift eka floor dekak athara nawathila. Door eka open wenne naha.', 'Singlish', 'Passenger lift', 1, 3, 'Emergency', 94.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 15:20:00', '2026-08-23 15:20:02', NULL, NULL, NULL, '2026-08-23 15:20:00', '2026-08-23 15:20:02'),
(72, 'TCK-HF-260823-B-ASG01', 87, 2, 4, 4, NULL, NULL, 'B-303', 'Access card reader is not working', 'Main entrance access card reader eka cards read karanne naha.', 'Singlish', 'Access card reader', 1, 13, 'High', 63.00, 'High', 'Assigned', 0, 0, 0, '2026-08-23 08:25:00', '2026-08-23 08:25:02', NULL, NULL, NULL, '2026-08-23 08:25:00', '2026-08-23 09:10:00'),
(73, 'TCK-HF-260822-B-PRG01', 114, 2, 17, 31, NULL, NULL, 'B-404', 'Common drain is overflowing', 'පහළ මහලේ පොදු ජලාපවහන මාර්ගයෙන් වතුර පිටවෙමින් තිබේ.', 'Sinhala', 'Drain line', 1, 5, 'High', 72.00, 'High', 'In Progress', 1, 0, 0, '2026-08-22 14:35:00', '2026-08-22 14:35:02', NULL, NULL, NULL, '2026-08-22 14:35:00', '2026-08-23 09:25:00'),
(74, 'TCK-HF-260821-B-CMP01', 109, 2, 19, 26, 467, NULL, 'B-505', 'Oil spill in corridor', 'There is an oil spill on the common corridor floor and it is slippery.', 'English', 'Floor surface', 1, 6, 'Low', 29.00, 'Low', 'Resolved', 1, 0, 0, '2026-08-21 13:25:00', '2026-08-21 13:25:02', '2026-08-21 14:35:00', NULL, NULL, '2026-08-21 13:25:00', '2026-08-29 13:38:14'),
(75, 'TCK-HF-260823-C-REV01', 123, 3, 10, 40, 29, NULL, 'C-101', 'New crack on bedroom wall', 'A new crack has appeared above the bedroom window. I am not sure if it is only plaster or structural.', 'English', 'Wall', 1, 12, 'High', 62.00, 'High', 'Awaiting Review', 0, 0, 1, '2026-08-23 14:25:00', '2026-08-23 14:25:02', NULL, NULL, NULL, '2026-08-23 14:25:00', '2026-08-29 13:38:14'),
(76, 'TCK-HF-260823-C-UNA01', 101, 3, 13, 18, 95, NULL, 'C-202', 'Smoke smell near electrical room', 'Electrical room eka langin strong smoke smell ekak enawa. Smoke poddak penenawath wage.', 'Mixed', 'Electrical room', 1, 10, 'Emergency', 100.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 15:30:00', '2026-08-23 15:30:02', NULL, NULL, NULL, '2026-08-23 15:30:00', '2026-08-29 13:38:14'),
(77, 'TCK-HF-260823-C-ASG01', 96, 3, 15, 13, 29, NULL, 'C-303', 'Window latch is broken', 'Bedroom window eke latch eka kadila. Window eka properly lock karanna baha.', 'Singlish', 'Window', 1, 8, 'Low', 31.00, 'Medium', 'Assigned', 0, 0, 0, '2026-08-23 08:35:00', '2026-08-23 08:35:02', NULL, NULL, NULL, '2026-08-23 08:35:00', '2026-08-29 13:38:14'),
(78, 'TCK-HF-260822-C-PRG01', 111, 3, 18, 28, 74, NULL, 'C-404', 'Kitchen sink pipe is leaking', 'Kitchen sink යට pipe එකෙන් water leak වෙනවා. Cabinet එකත් wet වෙලා.', 'Mixed', 'Sink pipe', 1, 2, 'Medium', 48.00, 'Medium', 'In Progress', 0, 0, 0, '2026-08-22 14:50:00', '2026-08-22 14:50:02', NULL, NULL, NULL, '2026-08-22 14:50:00', '2026-08-29 13:38:14'),
(79, 'TCK-HF-260821-C-CMP01', 89, 3, 20, 6, NULL, NULL, 'C-505', 'නිදන කාමරයේ AC එකෙන් වතුර බේරෙනවා', 'නිදන කාමරයේ AC එක සීතල කරනවා නමුත් ඇතුළත unit එකෙන් වතුර බේරෙනවා. කරුණාකර AC එක සහ drain line එක පරීක්ෂා කරන්න.', 'Sinhala', 'Air conditioner', 1, 4, 'Medium', 36.00, 'Medium', 'Resolved', 0, 0, 0, '2026-08-21 13:40:00', '2026-08-21 13:40:02', '2026-08-21 15:00:00', NULL, NULL, '2026-08-21 13:40:00', '2026-08-27 14:25:32'),
(80, 'TCK-HF-260823-D-REV01', 119, 4, 52, 36, NULL, NULL, 'D-101', 'Water pump is making a loud noise', 'The service water pump is making a louder vibration noise than usual. Please inspect it.', 'English', 'Water pump', 1, 9, 'Medium', 41.00, 'Medium', 'Awaiting Review', 0, 0, 1, '2026-08-23 14:35:00', '2026-08-23 14:35:02', NULL, NULL, NULL, '2026-08-23 14:35:00', '2026-08-23 14:35:02'),
(81, 'TCK-HF-260823-D-UNA01', 94, 4, 53, 11, NULL, NULL, 'D-202', 'Water close to electrical panel', 'Electrical panel එක අසල බිමට water leak වෙලා. Power area එකට ලං වෙලා තියෙනවා.', 'Mixed', 'Electrical panel', 1, 1, 'Emergency', 96.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 15:40:00', '2026-08-23 15:40:02', NULL, NULL, NULL, '2026-08-23 15:40:00', '2026-08-23 15:40:02'),
(82, 'TCK-HF-260823-D-ASG01', 91, 4, 54, 8, 784, NULL, 'D-303', 'Garbage room needs cleaning', 'Garbage room eke floor eka dirty wela smell ekak enawa. Cleaning ekak one.', 'Singlish', 'Garbage room', 1, 6, 'Low', 21.00, 'Low', 'Assigned', 0, 0, 0, '2026-08-23 08:45:00', '2026-08-23 08:45:02', NULL, NULL, NULL, '2026-08-23 08:45:00', '2026-08-29 13:38:14'),
(83, 'TCK-HF-260822-D-PRG01', 116, 4, 55, 33, NULL, NULL, 'D-404', 'Ant problem in pantry', 'Pantry area eke ants godak innawa. Food storage cupboard langath innawa.', 'Singlish', 'Pantry', 1, 7, 'Medium', 39.00, 'Medium', 'In Progress', 0, 0, 0, '2026-08-22 15:05:00', '2026-08-22 15:05:02', NULL, NULL, NULL, '2026-08-22 15:05:00', '2026-08-23 09:55:00'),
(84, 'TCK-HF-260821-D-CMP01', 99, 4, 56, 16, NULL, NULL, 'D-505', 'සිවිලිමේ ප්ලාස්ටර් ඉරිතැලීලා', 'විසිත්ත කාමරයේ සිවිලිමේ කෙළවර අසල ඉරිතැලීමක් සහ ලිහිල් ප්ලාස්ටර් කොටස් පේනවා. කරුණාකර පරීක්ෂා කරන්න.', 'Sinhala', 'Ceiling', 1, 12, 'High', 68.00, 'High', 'Resolved', 0, 0, 0, '2026-08-21 13:55:00', '2026-08-21 13:55:02', '2026-08-21 15:20:00', NULL, NULL, '2026-08-21 13:55:00', '2026-08-27 14:25:32'),
(85, 'TCK-HF-260823-E-REV01', 88, 7, 62, 5, NULL, NULL, 'E-101', 'Lift is making an unusual noise', 'The lift is operating but there is an unusual scraping noise when it passes the fourth floor.', 'English', 'Passenger lift', 1, 3, 'High', 58.00, 'Medium', 'Awaiting Review', 0, 0, 1, '2026-08-23 14:45:00', '2026-08-23 14:45:02', NULL, NULL, NULL, '2026-08-23 14:45:00', '2026-08-23 14:45:02'),
(86, 'TCK-HF-260823-E-UNA01', 102, 7, 63, 19, NULL, NULL, 'E-202', 'Strong gas smell in pantry', 'Pantry eke gas smell eka godak strong. Stove eka off karala thiyenne but smell eka thiyenawa.', 'Singlish', 'Gas line', 1, 11, 'Emergency', 99.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 15:50:00', '2026-08-23 15:50:02', NULL, NULL, NULL, '2026-08-23 15:50:00', '2026-08-23 15:50:02'),
(87, 'TCK-HF-260823-E-ASG01', 117, 7, 64, 34, 767, NULL, 'E-303', 'Bedroom circuit keeps tripping', 'Bedroom light circuit එක repeatedly trip වෙනවා. Other rooms are working normally.', 'Mixed', 'Circuit breaker', 1, 1, 'High', 59.00, 'Medium', 'Assigned', 0, 0, 0, '2026-08-23 08:55:00', '2026-08-23 08:55:02', NULL, NULL, NULL, '2026-08-23 08:55:00', '2026-08-29 13:38:14'),
(88, 'TCK-HF-260822-E-PRG01', 113, 7, 65, 30, 821, NULL, 'E-404', 'Parking gate is not closing', 'Parking gate eka open wenawa but automatically close wenne naha. Security issue ekak.', 'Singlish', 'Parking gate', 1, 13, 'High', 57.00, 'Medium', 'In Progress', 0, 0, 0, '2026-08-22 15:20:00', '2026-08-22 15:20:02', NULL, NULL, NULL, '2026-08-22 15:20:00', '2026-08-29 13:38:14'),
(89, 'TCK-HF-260821-E-CMP01', 108, 7, 66, 25, 765, NULL, 'E-505', 'ටොයිලට් සිස්ටර්න් එකෙන් වතුර කාන්දු වුණා', 'ටොයිලට් සිස්ටර්න් එකෙන් වතුර දිගටම bowl එකට කාන්දු වුණා. කරුණාකර valve එක සහ cistern mechanism එක පරීක්ෂා කරන්න.', 'Sinhala', 'Toilet cistern', 1, 2, 'Medium', 35.00, 'Medium', 'Resolved', 0, 0, 0, '2026-08-21 14:10:00', '2026-08-21 14:10:02', '2026-08-21 15:30:00', NULL, NULL, '2026-08-21 14:10:00', '2026-08-29 13:38:14'),
(90, 'TCK-HF-260820-A-REV02', 107, 1, 21, 24, NULL, NULL, 'A-606', 'Water pump pressure is unstable', 'Water pressure changes suddenly in the apartment and the service pump sounds different. Please review before assigning a technician.', 'English', 'Water pump', 1, 9, 'Medium', 46.00, 'Medium', 'Awaiting Review', 0, 0, 1, '2026-08-20 10:20:00', '2026-08-20 10:20:02', NULL, NULL, NULL, '2026-08-20 10:20:00', '2026-08-20 10:20:02'),
(91, 'TCK-HF-260820-D-UNA02', 105, 4, 57, 22, NULL, NULL, 'D-606', 'Fire alarm panel shows fault', 'The common area fire alarm panel is showing a fault warning and there is a faint burning smell nearby.', 'English', 'Fire alarm panel', 1, 10, 'Emergency', 98.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-20 11:15:00', '2026-08-20 11:15:02', NULL, NULL, NULL, '2026-08-20 11:15:00', '2026-08-20 11:15:02'),
(92, 'TCK-HF-260820-E-ASG02', 104, 7, 67, 21, 761, NULL, 'E-606', 'Balcony drain is blocked', 'Balcony drain eka block wela rain water collect wenawa. Drainage technician kenek assign karanna.', 'Singlish', 'Balcony drain', 1, 5, 'High', 64.00, 'High', 'Assigned', 0, 0, 0, '2026-08-20 09:10:00', '2026-08-20 09:10:02', NULL, NULL, NULL, '2026-08-20 09:10:00', '2026-08-29 13:38:14'),
(96, 'TCK-HF-260823-ML001', 100, 1, 11, 17, 72, NULL, 'A-202', 'Kitchen sink pipe is leaking', 'මුළුතැන්ගෙයි සින්ක් එක යටින් වතුර ලීක් වෙනවා. කැබිනට් එකත් තෙමීලා තියෙනවා.', 'Sinhala', 'Sink pipe', 1, 2, 'Medium', 46.00, 'Medium', 'Awaiting Review', 0, 0, 1, '2026-08-23 13:00:00', '2026-08-23 13:00:02', NULL, NULL, NULL, '2026-08-23 13:00:00', '2026-08-29 13:38:14'),
(97, 'TCK-HF-260823-ML002', 92, 1, 14, 9, 343, NULL, 'A-303', 'Corridor light keeps flickering', 'Third floor corridor light eka digatama blink wenawa. Raatriyata eka disturb wenawa.', 'Singlish', 'Ceiling light', 1, 1, 'Low', 28.00, 'Low', 'Awaiting Review', 0, 0, 1, '2026-08-23 13:17:00', '2026-08-23 13:17:02', NULL, NULL, NULL, '2026-08-23 13:17:00', '2026-08-29 13:38:14'),
(98, 'TCK-HF-260823-ML003', 95, 1, 16, 12, 27, NULL, 'A-404', 'Bedroom AC is dripping water', 'Bedroom AC එකෙන් water drops වැටෙනවා. Floor එක wet වෙන නිසා check කරන්න.', 'Mixed', 'Air conditioner', 1, 4, 'Medium', 42.00, 'Medium', 'Awaiting Review', 0, 0, 1, '2026-08-23 13:34:00', '2026-08-23 13:34:02', NULL, NULL, NULL, '2026-08-23 13:34:00', '2026-08-29 13:38:14'),
(99, 'TCK-HF-260823-ML004', 106, 1, 2, 23, 108, NULL, 'A-505', 'Parking gate sensor is unreliable', 'The parking entrance gate sometimes closes before the vehicle completely passes the sensor.', 'English', 'Gate sensor', 1, 13, 'Medium', 51.00, 'Medium', 'Awaiting Review', 0, 0, 1, '2026-08-23 13:51:00', '2026-08-23 13:51:02', NULL, NULL, NULL, '2026-08-23 13:51:00', '2026-08-29 13:38:14'),
(100, 'TCK-HF-260823-ML005', 107, 1, 21, 24, 24, NULL, 'A-606', 'Bathroom drain is very slow', 'නානකාමරයේ ජලාපවහන කාණුව හෙමින් බැස යනවා සහ වතුර එකතු වෙනවා.', 'Sinhala', 'Floor drain', 1, 5, 'Medium', 39.00, 'Medium', 'Awaiting Review', 0, 0, 1, '2026-08-23 14:08:00', '2026-08-23 14:08:02', NULL, NULL, NULL, '2026-08-23 14:08:00', '2026-08-29 13:38:14'),
(101, 'TCK-HF-260823-ML006', 103, 1, 24, 20, 72, NULL, 'A-707', 'Kitchen cupboard hinge is loose', 'Kitchen cupboard door eke hinge eka loose wela. Door eka hariyata close wenne naha.', 'Singlish', 'Cupboard', 1, 8, 'Low', 22.00, 'Low', 'Awaiting Review', 0, 0, 1, '2026-08-23 14:25:00', '2026-08-23 14:25:02', NULL, NULL, NULL, '2026-08-23 14:25:00', '2026-08-29 13:38:14'),
(102, 'TCK-HF-260823-ML007', 110, 1, 27, 27, 72, NULL, 'A-808', 'Ants inside kitchen cabinet', 'Kitchen cabinet එක ඇතුළේ ants ගොඩක් තියෙනවා. Food packets ළඟටත් එනවා.', 'Mixed', 'Kitchen cabinet', 1, 7, 'Low', 25.00, 'Low', 'Awaiting Review', 0, 0, 1, '2026-08-23 14:42:00', '2026-08-23 14:42:02', NULL, NULL, NULL, '2026-08-23 14:42:00', '2026-08-29 13:38:14'),
(103, 'TCK-HF-260823-ML008', 118, 2, 9, 35, NULL, NULL, 'B-101', 'Lift door closes too slowly', 'The passenger lift door on my floor stays open much longer than normal before closing.', 'English', 'Passenger lift', 1, 3, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 0, 1, '2026-08-23 14:59:00', '2026-08-23 14:59:02', NULL, NULL, NULL, '2026-08-23 14:59:00', '2026-08-23 14:59:02'),
(104, 'TCK-HF-260823-ML009', 121, 2, 12, 38, 465, NULL, 'B-202', 'Smoke smell in the common corridor', 'පොදු කොරිඩෝරයේ දුම් සුවඳක් එනවා සහ දුම් අනතුරු සංඥා උපකරණය දිගටම හඬනවා.', 'Sinhala', 'Smoke detector', 1, 10, 'Emergency', 96.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 17:00:00', '2026-08-23 17:00:02', NULL, NULL, NULL, '2026-08-23 17:00:00', '2026-08-29 13:38:14'),
(105, 'TCK-HF-260823-ML010', 87, 2, 4, 4, 73, NULL, 'B-303', 'Strong gas smell near kitchen valve', 'Kitchen gas line eka langin gas smell ekak enawa. Valve eka close kalath smell eka thiyenawa.', 'Singlish', 'Gas valve', 1, 11, 'Emergency', 98.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 17:17:00', '2026-08-23 17:17:02', NULL, NULL, NULL, '2026-08-23 17:17:00', '2026-08-29 13:38:14'),
(106, 'TCK-HF-260823-ML011', 114, 2, 17, 31, 73, NULL, 'B-404', 'Water leaking beside an electrical switch', 'Kitchen switch එක ළඟ water leak එකක් තියෙනවා සහ switch එකෙන් small spark එකක් දැක්කා.', 'Mixed', 'Wall switch', 1, 1, 'Emergency', 99.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 17:34:00', '2026-08-23 17:34:02', NULL, NULL, NULL, '2026-08-23 17:34:00', '2026-08-29 13:38:14'),
(107, 'TCK-HF-260823-ML012', 109, 2, 19, 26, 467, NULL, 'B-505', 'Ceiling material is falling', 'A section of the common corridor ceiling is cracking and small concrete pieces are falling to the floor.', 'English', 'Ceiling', 1, 12, 'Emergency', 93.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 17:51:00', '2026-08-23 17:51:02', NULL, NULL, NULL, '2026-08-23 17:51:00', '2026-08-29 13:38:14'),
(108, 'TCK-HF-260823-ML013', 97, 2, 22, 14, 25, NULL, 'B-606', 'Main bathroom pipe has burst', 'නානකාමරයේ ප්‍රධාන ජල නළයෙන් වතුර වේගයෙන් පිටවෙමින් තියෙනවා. බිම ඉක්මනින් වතුරෙන් පිරෙනවා.', 'Sinhala', 'Water pipe', 1, 2, 'Emergency', 95.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 18:08:00', '2026-08-23 18:08:02', NULL, NULL, NULL, '2026-08-23 18:08:00', '2026-08-29 13:38:14'),
(109, 'TCK-HF-260823-ML014', 93, 2, 25, 10, NULL, NULL, 'B-707', 'Burning smell from air conditioner', 'AC eka on karaddi burning smell ekak enawa. Unit eka athulen podi smoke wage penuna.', 'Singlish', 'Air conditioner', 1, 4, 'Emergency', 94.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 18:25:00', '2026-08-23 18:25:02', NULL, NULL, NULL, '2026-08-23 18:25:00', '2026-08-23 18:25:02'),
(110, 'TCK-HF-260823-ML015', 90, 2, 28, 7, NULL, NULL, 'B-808', 'Emergency exit door will not unlock', 'Emergency exit door එකේ lock එක stuck වෙලා. Handle එක press කළත් door එක open වෙන්නේ නැහැ.', 'Mixed', 'Emergency exit door', 1, 13, 'Emergency', 91.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 18:42:00', '2026-08-23 18:42:02', NULL, NULL, NULL, '2026-08-23 18:42:00', '2026-08-23 18:42:02'),
(111, 'TCK-HF-260823-ML016', 123, 3, 10, 40, NULL, NULL, 'C-101', 'Chemical liquid spilled in stairwell', 'A strong-smelling cleaning chemical has spilled across the stairwell and residents are reporting eye irritation.', 'English', 'Stairwell floor', 1, 6, 'Emergency', 89.00, 'Critical', 'Urgent Unassigned', 1, 0, 0, '2026-08-23 18:59:00', '2026-08-23 18:59:02', NULL, NULL, NULL, '2026-08-23 18:59:00', '2026-08-23 18:59:02'),
(112, 'TCK-HF-260822-ML017', 101, 3, 13, 18, NULL, NULL, 'C-202', 'Lift door jerks while opening', 'ලිෆ්ට් එක දෙවන මහලේ දොර අරිනකොට ගැස්සෙනවා සහ දොර නැවත වැසෙන්න ප්‍රමාද වෙනවා.', 'Sinhala', 'Passenger lift', 1, 3, 'High', 72.00, 'High', 'Assigned', 1, 0, 0, '2026-08-22 08:00:00', '2026-08-22 08:00:02', NULL, NULL, NULL, '2026-08-22 08:00:00', '2026-08-22 08:38:00'),
(113, 'TCK-HF-260822-ML018', 96, 3, 15, 13, 26, NULL, 'C-303', 'Sewage is backing up through drain', 'Bathroom drain eken sewage back wenawa. Bad smell ekak thiyenawa saha floor eka wet.', 'Singlish', 'Waste drain', 1, 5, 'High', 78.00, 'High', 'Assigned', 1, 0, 0, '2026-08-22 08:17:00', '2026-08-22 08:17:02', NULL, NULL, NULL, '2026-08-22 08:17:00', '2026-08-29 13:38:14'),
(114, 'TCK-HF-260822-ML019', 111, 3, 18, 28, NULL, NULL, 'C-404', 'Fire alarm panel shows a fault', 'Fire alarm panel එකේ red fault light එක on වෙලා. Common area alarm system එක check කරන්න.', 'Mixed', 'Fire alarm panel', 1, 10, 'High', 74.00, 'High', 'Assigned', 1, 0, 0, '2026-08-22 08:34:00', '2026-08-22 08:34:02', NULL, NULL, NULL, '2026-08-22 08:34:00', '2026-08-22 09:12:00'),
(115, 'TCK-HF-260822-ML020', 89, 3, 20, 6, NULL, NULL, 'C-505', 'Circuit breaker trips repeatedly', 'The apartment distribution board breaker trips again a few minutes after it is reset.', 'English', 'Distribution board', 1, 1, 'High', 68.00, 'High', 'Assigned', 1, 0, 0, '2026-08-22 08:51:00', '2026-08-22 08:51:02', NULL, NULL, NULL, '2026-08-22 08:51:00', '2026-08-22 09:29:00'),
(116, 'TCK-HF-260822-ML021', 120, 3, 23, 37, 20, NULL, 'C-606', 'Wasp nest near balcony roof', 'බැල්කනියේ වහලයට අසල බඹර කූඩුවක් තියෙනවා. ළමයි ඉන්න නිසා ඉවත් කරන්න.', 'Sinhala', 'Balcony roof', 1, 7, 'Medium', 54.00, 'Medium', 'Assigned', 1, 0, 0, '2026-08-22 09:08:00', '2026-08-22 09:08:02', NULL, NULL, NULL, '2026-08-22 09:08:00', '2026-08-29 13:38:14'),
(117, 'TCK-HF-260822-ML022', 115, 3, 26, 32, NULL, NULL, 'C-707', 'Service water pump is noisy', 'Water pump eka start weddi loku vibration sound ekak enawa. Kalin mehema tibbe naha.', 'Singlish', 'Water pump', 1, 9, 'Medium', 43.00, 'Medium', 'Assigned', 0, 0, 0, '2026-08-22 09:25:00', '2026-08-22 09:25:02', NULL, NULL, NULL, '2026-08-22 09:25:00', '2026-08-22 10:03:00'),
(118, 'TCK-HF-260822-ML023', 98, 3, 7, 15, 20, NULL, 'C-808', 'Balcony door handle is loose', 'Balcony door handle එක loose වෙලා. Lock කරන්න ගියාම handle එක rotate වෙනවා.', 'Mixed', 'Balcony door', 1, 8, 'Low', 29.00, 'Low', 'Assigned', 0, 0, 0, '2026-08-22 09:42:00', '2026-08-22 09:42:02', NULL, NULL, NULL, '2026-08-22 09:42:00', '2026-08-29 13:38:14'),
(119, 'TCK-HF-260822-ML024', 119, 4, 52, 36, 764, NULL, 'D-101', 'ටොයිලට් සිස්ටර්න් එක දිගටම වතුර යවනවා', 'flush කළ පසුත් ටොයිලට් සිස්ටර්න් එකෙන් වතුර දිගටම ගලා යනවා. මේ නිසා වතුර අපතේ යනවා. කරුණාකර පරීක්ෂා කරන්න.', 'Sinhala', 'Toilet cistern', 1, 2, 'Medium', 38.00, 'Medium', 'Assigned', 0, 0, 0, '2026-08-22 09:59:00', '2026-08-22 09:59:02', NULL, NULL, NULL, '2026-08-22 09:59:00', '2026-08-29 13:38:14'),
(120, 'TCK-HF-260821-ML025', 94, 4, 53, 11, 1027, NULL, 'D-202', 'Two corridor lights are not working', 'හයවන මහලේ කොරිඩෝරයේ ලයිට් දෙකක් වැඩ කරන්නේ නැහැ. රාත්‍රියේ අඳුරුයි.', 'Sinhala', 'Corridor lighting', 1, 1, 'Medium', 41.00, 'Medium', 'In Progress', 0, 0, 0, '2026-08-21 09:00:00', '2026-08-21 09:00:02', NULL, NULL, NULL, '2026-08-21 09:00:00', '2026-08-29 13:38:14'),
(121, 'TCK-HF-260821-ML026', 91, 4, 54, 8, 792, NULL, 'D-303', 'Lobby intercom audio is unclear', 'Lobby intercom eken voice eka clear naha. Visitor kenek kata karaddi sound eka cut wenawa.', 'Singlish', 'Intercom', 1, 13, 'Medium', 37.00, 'Medium', 'In Progress', 0, 0, 0, '2026-08-21 09:17:00', '2026-08-21 09:17:02', NULL, NULL, NULL, '2026-08-21 09:17:00', '2026-08-29 13:38:14'),
(122, 'TCK-HF-260821-ML027', 116, 4, 55, 33, 802, NULL, 'D-404', 'Living room AC is not cooling', 'Living room AC එක on වෙනවා but cooling හරිම අඩුයි. Outdoor unit එක run වෙනවා.', 'Mixed', 'Air conditioner', 1, 4, 'Medium', 45.00, 'Medium', 'In Progress', 0, 0, 0, '2026-08-21 09:34:00', '2026-08-21 09:34:02', NULL, NULL, NULL, '2026-08-21 09:34:00', '2026-08-29 13:38:14'),
(123, 'TCK-HF-260821-ML028', 99, 4, 56, 16, 760, NULL, 'D-505', 'Balcony floor tile is lifting', 'One balcony floor tile has lifted above the surrounding tiles and feels hollow when stepped on.', 'English', 'Balcony floor', 1, 12, 'High', 63.00, 'High', 'In Progress', 0, 0, 0, '2026-08-21 09:51:00', '2026-08-21 09:51:02', NULL, NULL, NULL, '2026-08-21 09:51:00', '2026-08-29 13:38:14'),
(124, 'TCK-HF-260821-ML029', 105, 4, 57, 22, NULL, NULL, 'D-606', 'Slippery liquid on stair landing', 'පඩිපෙළේ තෙල් වගේ දියරයක් වැටිලා බිම ලිස්සනවා. පිරිසිදු කරන්න.', 'Sinhala', 'Stair landing', 1, 6, 'Medium', 35.00, 'Medium', 'In Progress', 1, 0, 0, '2026-08-21 10:08:00', '2026-08-21 10:08:02', NULL, NULL, NULL, '2026-08-21 10:08:00', '2026-08-21 11:07:00'),
(125, 'TCK-HF-260821-ML030', 124, 4, 58, 41, 760, NULL, 'D-707', 'Balcony drain is blocked', 'Balcony drain eka slow. Wessa wela passe water tika balcony eke collect wenawa.', 'Singlish', 'Balcony drain', 1, 5, 'Medium', 49.00, 'Medium', 'In Progress', 0, 0, 0, '2026-08-21 10:25:00', '2026-08-21 10:25:02', NULL, NULL, NULL, '2026-08-21 10:25:00', '2026-08-29 13:38:14'),
(126, 'TCK-HF-260821-ML031', 88, 7, 62, 5, NULL, NULL, 'E-101', 'Lift has unusual vibration', 'Lift එක move වෙද්දි unusual vibration එකක් දැනෙනවා. Especially fourth floor ළඟ වැඩියි.', 'Mixed', 'Passenger lift', 1, 3, 'High', 70.00, 'High', 'In Progress', 1, 0, 0, '2026-08-21 10:42:00', '2026-08-21 10:42:02', NULL, NULL, NULL, '2026-08-21 10:42:00', '2026-08-21 11:41:00'),
(127, 'TCK-HF-260818-ML032', 102, 7, 63, 19, 797, NULL, 'E-202', 'Gas regulator connection was loose', 'The kitchen gas regulator connection felt loose and there was a slight smell near the cylinder cabinet.', 'English', 'Gas regulator', 1, 11, 'High', 66.00, 'High', 'Resolved', 1, 0, 0, '2026-08-18 10:29:00', '2026-08-18 10:29:02', '2026-08-18 12:44:00', NULL, NULL, '2026-08-18 10:29:00', '2026-08-29 13:38:14'),
(128, 'TCK-HF-260818-ML033', 117, 7, 64, 34, NULL, NULL, 'E-303', 'Emergency light was not working', 'හදිසි පිටවීමේ මාර්ගයේ හදිසි ආලෝක පද්ධතිය වැඩ කරන්නේ නැහැ.', 'Sinhala', 'Emergency light', 1, 10, 'High', 64.00, 'High', 'Resolved', 1, 0, 0, '2026-08-18 08:30:00', '2026-08-18 08:30:02', '2026-08-18 10:15:00', NULL, NULL, '2026-08-18 08:30:00', '2026-08-18 10:15:00'),
(129, 'TCK-HF-260818-ML034', 113, 7, 65, 30, NULL, NULL, 'E-404', 'Main door was scraping the floor', 'Main door eka floor ekata scrape wenawa. Open close karanna amarui.', 'Singlish', 'Main door', 1, 8, 'Low', 26.00, 'Low', 'Resolved', 0, 0, 0, '2026-08-18 08:47:00', '2026-08-18 08:47:02', '2026-08-18 10:47:00', NULL, NULL, '2026-08-18 08:47:00', '2026-08-18 10:47:00'),
(130, 'TCK-HF-260818-ML035', 108, 7, 66, 25, NULL, NULL, 'E-505', 'Washing machine inlet hose was leaking', 'Washing machine inlet hose එකෙන් water leak වෙනවා. Tap එක open කළාම leak එක වැඩි වෙනවා.', 'Mixed', 'Inlet hose', 1, 2, 'Medium', 44.00, 'Medium', 'Resolved', 0, 0, 0, '2026-08-18 09:04:00', '2026-08-18 09:04:02', '2026-08-18 11:19:00', NULL, NULL, '2026-08-18 09:04:00', '2026-08-18 11:19:00'),
(131, 'TCK-HF-260818-ML036', 104, 7, 67, 21, NULL, NULL, 'E-606', 'ලී දොර රාමුවේ වේයන්ගේ සලකුණු', 'නිදන කාමරයේ ලී දොර රාමුව සහ skirting අසල කුඩා වේයන්ගේ මාර්ග සහ සලකුණු පේනවා. කරුණාකර පළිබෝධ පාලන පරීක්ෂාවක් කරන්න.', 'Sinhala', 'Door frame', 1, 7, 'Medium', 52.00, 'Medium', 'Resolved', 0, 0, 0, '2026-08-18 09:21:00', '2026-08-18 09:21:02', '2026-08-18 11:06:00', NULL, NULL, '2026-08-18 09:21:00', '2026-08-27 14:25:32'),
(132, 'TCK-HF-260818-ML037', 122, 7, 68, 39, NULL, NULL, 'E-707', 'Access card reader missed valid cards', 'ප්‍රධාන දොරේ ප්‍රවේශ කාඩ්පත් කියවනය සමහර කාඩ්පත් හඳුනා ගන්නේ නැහැ.', 'Sinhala', 'Access card reader', 1, 13, 'Medium', 47.00, 'Medium', 'Resolved', 0, 0, 0, '2026-08-18 09:38:00', '2026-08-18 09:38:02', '2026-08-18 11:38:00', NULL, NULL, '2026-08-18 09:38:00', '2026-08-18 11:38:00'),
(133, 'TCK-260826-140CCD38', 115, 3, 26, 32, 26, NULL, 'C-707', 'නාන කාමරයේ වතුර බටය කැඩී වතුර ගලා යනවා', 'නාන කාමරයේ වතුර බටයක් කැඩී ඇති අතර විශාල වශයෙන් වතුර ගලා යනවා. බිමට වතුර පිරෙමින් තිබෙන නිසා ඉක්මනින් පරීක්ෂා කර අලුත්වැඩියා කරන්න.', 'Mixed', 'වතුර බටය', 0, 2, 'High', 53.20, 'Medium', 'Resolved', 0, 0, 0, '2026-08-26 18:44:33', '2026-08-26 18:44:35', '2026-08-26 19:02:08', NULL, NULL, '2026-08-26 18:44:33', '2026-08-26 19:02:08'),
(134, 'TCK-HF-260827-A-R092', 92, 1, 14, NULL, 331, NULL, NULL, 'Lift making grinding noise at this floor', 'Lift eka me floor eke nawathinawata grinding wage saddayak enawa. Ada kihipa parakma eka una.', 'Singlish', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-24 08:15:00', '2026-08-24 08:15:02', NULL, NULL, NULL, '2026-08-24 08:15:00', '2026-08-24 08:15:02'),
(135, 'TCK-HF-260827-A-R095', 95, 1, 14, NULL, 331, NULL, NULL, 'Lift making grinding noise at this floor - repeated report', 'Lift එක මේ floor එකේ stop වෙනකොට grinding noise එකක් එනවා. අද කිහිප වතාවක්ම වුණා. Same location එකේ මේ issue එක නැවතත් පේනවා.', 'Mixed', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 1, 1, '2026-08-24 09:28:00', '2026-08-24 09:28:02', NULL, NULL, NULL, '2026-08-24 09:28:00', '2026-08-24 09:28:02'),
(136, 'TCK-HF-260827-A-R100', 100, 1, 11, NULL, 342, NULL, NULL, 'Water leak in common corridor', 'පොදු කොරිඩෝරයේ පයිප් එකකින් වතුර කාන්දු වෙනවා සහ ගමන් මාර්ගය අසල බිම තෙත් වෙනවා.', 'Sinhala', 'Water Pipe', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-24 10:41:00', '2026-08-24 10:41:02', NULL, NULL, NULL, '2026-08-24 10:41:00', '2026-08-24 10:41:02'),
(137, 'TCK-HF-260827-A-R103', 103, 1, 11, NULL, 342, NULL, NULL, 'Water leak in common corridor - repeated report', 'Common corridor eke pipe ekakin wathura leak wenawa. Walkway eka langa floor eka wet wenawa. Me location ekema same issue eka aye penuna.', 'Singlish', 'Water Pipe', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 1, 1, '2026-08-24 11:54:00', '2026-08-24 11:54:02', NULL, NULL, NULL, '2026-08-24 11:54:00', '2026-08-24 11:54:02'),
(138, 'TCK-HF-260827-A-R106', 106, 1, 2, NULL, 340, NULL, NULL, 'පොදු කොරිඩෝරයේ ලයිට් දිලිසෙනවා', 'පොදු කොරිඩෝරයේ ලයිට් කිහිපයක් දිලිසෙන අතර තත්පර කිහිපයකට නිවී නැවත දැල්වෙනවා. කරුණාකර විදුලි සම්බන්ධතාවය පරීක්ෂා කරන්න.', 'Sinhala', 'Lighting', 1, 1, 'High', 68.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-24 13:07:00', '2026-08-24 13:07:02', NULL, NULL, NULL, '2026-08-24 13:07:00', '2026-08-27 14:25:32'),
(139, 'TCK-HF-260827-A-R107', 107, 1, 2, NULL, 340, NULL, NULL, 'Common corridor lights flickering - repeated report', 'පොදු කොරිඩෝරයේ ලයිට් කිහිපයක් දිලිසෙමින් තත්පර කිහිපයකට නිවී නැවත දැල්වෙනවා. මේ ස්ථානයේම එම ගැටලුව තවත් වරක් දක්නට ලැබුණා.', 'Sinhala', 'Lighting', 1, 1, 'High', 68.00, 'High', 'Awaiting Review', 0, 1, 1, '2026-08-24 14:20:00', '2026-08-24 14:20:02', NULL, NULL, NULL, '2026-08-24 14:20:00', '2026-08-24 14:20:02'),
(140, 'TCK-HF-260827-A-R110', 110, 1, 27, 27, 27, NULL, 'A-808', 'Bedroom door not closing properly', 'Bedroom door එක properly close වෙන්නේ නැහැ. Please check the hinges and frame.', 'Mixed', 'Door', 1, 8, 'Low', 25.00, 'Low', 'Awaiting Review', 0, 0, 0, '2026-08-24 15:33:00', '2026-08-24 15:33:02', NULL, NULL, NULL, '2026-08-24 15:33:00', '2026-08-24 15:33:02'),
(141, 'TCK-HF-260827-A-R112', 112, 1, 8, 29, 42, NULL, 'A-101', 'ප්‍රධාන දොරේ අගුල හරියට වැටෙන්නේ නැහැ', 'ප්‍රධාන දොර පළමු වරට වැසූ විට අගුල හරියට වැටෙන්නේ නැහැ. කරුණාකර අගුල් යාන්ත්‍රණය සහ දොරේ සවි කිරීම පරීක්ෂා කරන්න.', 'Sinhala', 'Door Lock', 1, 13, 'High', 65.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-24 16:46:00', '2026-08-24 16:46:02', NULL, NULL, NULL, '2026-08-24 16:46:00', '2026-08-27 14:25:32'),
(142, 'TCK-HF-260827-A-R125', 125, 1, 29, 68, 24, NULL, 'A-903', 'Bathroom tap eka leak wenawa', 'Bathroom tap eka full close kalath wathura leak wenawa. Tap eka saha pipe connection eka check karanna.', 'Singlish', 'Tap', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-24 17:59:00', '2026-08-24 17:59:02', NULL, NULL, NULL, '2026-08-24 17:59:00', '2026-08-27 14:25:32'),
(143, 'TCK-HF-260827-A-R126', 126, 1, 32, 69, 24, NULL, 'A-1004', 'Drain water flowing slowly', 'ඩ්‍රේන් එකෙන් වතුර ඉතා හෙමින් බැස යන අතර වතුර එකතු වෙනවා. කරුණාකර අවහිරයක් තිබේද පරීක්ෂා කරන්න.', 'Sinhala', 'Drain', 1, 5, 'High', 62.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-24 19:12:00', '2026-08-24 19:12:02', NULL, NULL, NULL, '2026-08-24 19:12:00', '2026-08-24 19:12:02'),
(144, 'TCK-HF-260827-A-R127', 127, 1, 38, 70, 72, NULL, 'A-1202', 'Pest activity in kitchen', 'Kitchen area එකේ evening time small cockroaches පේනවා. Please arrange pest control.', 'Mixed', 'Kitchen Area', 1, 7, 'Low', 28.00, 'Low', 'Awaiting Review', 0, 0, 0, '2026-08-24 20:25:00', '2026-08-24 20:25:02', NULL, NULL, NULL, '2026-08-24 20:25:00', '2026-08-24 20:25:02'),
(145, 'TCK-HF-260827-A-R128', 128, 1, 44, 71, 18, NULL, 'A-1405', 'Loose fitting needs repair', 'Apartment eke fitting ekak loose wela. Thawa damage wenna kalin eka secure karanna.', 'Singlish', 'General Fitting', 1, 9, 'Medium', 38.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-24 21:38:00', '2026-08-24 21:38:02', NULL, NULL, NULL, '2026-08-24 21:38:00', '2026-08-24 21:38:02'),
(146, 'TCK-HF-260827-A-R129', 129, 1, 47, 72, 42, NULL, 'A-1506', 'Entrance door lock eka hariyata lock wenne naha', 'Entrance door eka first try eke hariyata lock wenne naha. Lock mechanism eka saha door alignment eka check karanna.', 'Singlish', 'Door Lock', 1, 13, 'High', 65.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-24 22:51:00', '2026-08-24 22:51:02', NULL, NULL, NULL, '2026-08-24 22:51:00', '2026-08-27 14:25:32'),
(147, 'TCK-HF-260827-B-R087', 87, 2, 4, NULL, 451, NULL, NULL, 'Lift making grinding noise at this floor', 'Lift eka me floor eke nawathinawata grinding wage saddayak enawa. Ada kihipa parakma eka una.', 'Singlish', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-25 00:04:00', '2026-08-25 00:04:02', NULL, NULL, NULL, '2026-08-25 00:04:00', '2026-08-25 00:04:02'),
(148, 'TCK-HF-260827-B-R090', 90, 2, 4, NULL, 451, NULL, NULL, 'Lift making grinding noise at this floor - repeated report', 'Lift එක මේ floor එකේ stop වෙනකොට grinding noise එකක් එනවා. අද කිහිප වතාවක්ම වුණා. Same location එකේ මේ issue එක නැවතත් පේනවා.', 'Mixed', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 1, 1, '2026-08-25 01:17:00', '2026-08-25 01:17:02', NULL, NULL, NULL, '2026-08-25 01:17:00', '2026-08-25 01:17:02'),
(149, 'TCK-HF-260827-B-R093', 93, 2, 25, NULL, 469, NULL, NULL, 'Water leak in common corridor', 'Common corridor eke pipe ekakin wathura leak wenawa. Walkway eka langa floor eka wet wenawa.', 'Singlish', 'Water Pipe', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-25 02:30:00', '2026-08-25 02:30:02', NULL, NULL, NULL, '2026-08-25 02:30:00', '2026-08-25 02:30:02'),
(150, 'TCK-HF-260827-B-R097', 97, 2, 25, NULL, 469, NULL, NULL, 'Water leak in common corridor - repeated report', 'පොදු කොරිඩෝරයේ පයිප් එකකින් වතුර කාන්දු වෙනවා සහ ගමන් මාර්ගය අසල බිම තෙත් වෙනවා. මේ ස්ථානයේම එම ගැටලුව තවත් වරක් දක්නට ලැබුණා.', 'Sinhala', 'Water Pipe', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 1, 1, '2026-08-25 03:43:00', '2026-08-25 03:43:02', NULL, NULL, NULL, '2026-08-25 03:43:00', '2026-08-25 03:43:02'),
(151, 'TCK-HF-260827-B-R109', 109, 2, 19, NULL, 467, NULL, NULL, 'පොදු කොරිඩෝරයේ ලයිට් දිලිසෙනවා', 'පොදු කොරිඩෝරයේ ලයිට් කිහිපයක් දිලිසෙන අතර තත්පර කිහිපයකට නිවී නැවත දැල්වෙනවා. කරුණාකර විදුලි පද්ධතිය පරීක්ෂා කරන්න.', 'Sinhala', 'Lighting', 1, 1, 'High', 68.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-25 04:56:00', '2026-08-25 04:56:02', NULL, NULL, NULL, '2026-08-25 04:56:00', '2026-08-27 14:25:32'),
(152, 'TCK-HF-260827-B-R114', 114, 2, 19, NULL, 467, NULL, NULL, 'Common corridor lights flickering - repeated report', 'Common corridor එකේ lights කිහිපයක් flicker වෙනවා සහ seconds කිහිපයකට off වෙනවා. Same location එකේ මේ issue එක නැවතත් පේනවා.', 'Mixed', 'Lighting', 1, 1, 'High', 68.00, 'High', 'Awaiting Review', 0, 1, 1, '2026-08-25 06:09:00', '2026-08-25 06:09:02', NULL, NULL, NULL, '2026-08-25 06:09:00', '2026-08-25 06:09:02'),
(153, 'TCK-HF-260827-B-R118', 118, 2, 9, 35, 73, NULL, 'B-101', 'Kitchen eke cockroach la penenawa', 'Hawasata kitchen area eke podi cockroach la penenawa. Pest control service ekak arrange karanna.', 'Singlish', 'Kitchen Area', 1, 7, 'Low', 28.00, 'Low', 'Awaiting Review', 0, 0, 0, '2026-08-25 07:22:00', '2026-08-25 07:22:02', NULL, NULL, NULL, '2026-08-25 07:22:00', '2026-08-27 14:25:32'),
(154, 'TCK-HF-260827-B-R121', 121, 2, 12, 38, 43, NULL, 'B-202', 'Door lock not securing properly', 'ප්‍රධාන දොරේ lock එක පළමු වරට හරියට අගුළු වැටෙන්නේ නැහැ. කරුණාකර lock mechanism එක පරීක්ෂා කරන්න.', 'Sinhala', 'Door Lock', 1, 13, 'High', 65.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-25 08:35:00', '2026-08-25 08:35:02', NULL, NULL, NULL, '2026-08-25 08:35:00', '2026-08-25 08:35:02'),
(155, 'TCK-HF-260827-B-R130', 130, 2, 30, 73, 37, NULL, 'B-902', 'Small ceiling crack noticed', 'සිවිලිමේ කුඩා ඉරිතැලීමක් පෙනෙන අතර එය මෑතකදී වඩා පැහැදිලි වී ඇත. කරුණාකර පරීක්ෂා කරන්න.', 'Sinhala', 'Ceiling', 1, 12, 'High', 72.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-25 09:48:00', '2026-08-25 09:48:02', NULL, NULL, NULL, '2026-08-25 09:48:00', '2026-08-25 09:48:02'),
(156, 'TCK-HF-260827-B-R131', 131, 2, 33, 74, 568, NULL, 'B-1003', 'Lift eka nawathinawata unusual saddayak enawa', 'Lift eka floor eke nawathinawata unusual saddayak enawa. Lift operation eka check karanna.', 'Singlish', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-25 11:01:00', '2026-08-25 11:01:02', NULL, NULL, NULL, '2026-08-25 11:01:00', '2026-08-27 14:25:32'),
(157, 'TCK-HF-260827-B-R132', 132, 2, 39, 75, 25, NULL, 'B-1204', 'Bathroom tap leaking', 'Bathroom tap එක close කළත් water leak වෙනවා. Please check the tap and pipe connection.', 'Mixed', 'Tap', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-25 12:14:00', '2026-08-25 12:14:02', NULL, NULL, NULL, '2026-08-25 12:14:00', '2026-08-25 12:14:02'),
(158, 'TCK-HF-260827-B-R133', 133, 2, 45, 76, 25, NULL, 'B-1402', 'Drain water flowing slowly', 'Drain eken wathura godak himin bahinawa saha wathura ekathu wenawa. Block ekak thiyenawada check karanna.', 'Singlish', 'Drain', 1, 5, 'High', 62.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-25 13:27:00', '2026-08-25 13:27:02', NULL, NULL, NULL, '2026-08-25 13:27:00', '2026-08-25 13:27:02'),
(159, 'TCK-HF-260827-C-R089', 89, 3, 20, NULL, 80, NULL, NULL, 'ලිෆ්ට් එක නවත්වන විට ගැටෙන වගේ ශබ්දයක් එනවා', 'ලිෆ්ට් එක මේ මහලේ නවත්වන විට ගැටෙන වගේ ශබ්දයක් එනවා. අද කිහිප වතාවක්ම මේ ශබ්දය ඇසුණා. කරුණාකර පරීක්ෂා කරන්න.', 'Sinhala', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-25 14:40:00', '2026-08-25 14:40:02', NULL, NULL, NULL, '2026-08-25 14:40:00', '2026-08-27 14:25:32'),
(160, 'TCK-HF-260827-C-R096', 96, 3, 20, NULL, 80, NULL, NULL, 'Lift making grinding noise at this floor - repeated report', 'Lift eka me floor eke nawathinawata grinding wage saddayak enawa. Ada kihipa parakma eka una. Me location ekema same issue eka aye penuna.', 'Singlish', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 1, 1, '2026-08-25 15:53:00', '2026-08-25 15:53:02', NULL, NULL, NULL, '2026-08-25 15:53:00', '2026-08-25 15:53:02'),
(161, 'TCK-HF-260827-C-R098', 98, 3, 7, NULL, 588, NULL, NULL, 'Water leak in common corridor', 'Common corridor එකේ pipe එකකින් water leak වෙනවා. Walkway එක ලඟ floor එක wet වෙලා.', 'Mixed', 'Water Pipe', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-25 17:06:00', '2026-08-25 17:06:02', NULL, NULL, NULL, '2026-08-25 17:06:00', '2026-08-29 13:38:14'),
(162, 'TCK-HF-260827-C-R101', 101, 3, 7, NULL, 588, NULL, NULL, 'Water leak in common corridor - repeated report', 'පොදු කොරිඩෝරයේ පයිප් එකකින් වතුර කාන්දු වෙනවා සහ ගමන් මාර්ගය අසල බිම තෙත් වෙනවා. මේ ස්ථානයේම එම ගැටලුව තවත් වරක් දක්නට ලැබුණා.', 'Sinhala', 'Water Pipe', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 1, 1, '2026-08-25 18:19:00', '2026-08-25 18:19:02', NULL, NULL, NULL, '2026-08-25 18:19:00', '2026-08-29 13:38:14'),
(163, 'TCK-HF-260827-C-R111', 111, 3, 18, NULL, 700, NULL, NULL, 'Common corridor lights flickering', 'Common corridor එකේ lights කිහිපයක් flicker වෙනවා සහ seconds කිහිපයකට off වෙනවා.', 'Mixed', 'Lighting', 1, 1, 'High', 68.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-25 19:32:00', '2026-08-25 19:32:02', NULL, NULL, NULL, '2026-08-25 19:32:00', '2026-08-29 13:38:14'),
(164, 'TCK-HF-260827-C-R115', 115, 3, 18, NULL, 700, NULL, NULL, 'Common corridor lights flickering - repeated report', 'Common corridor eke lights kihipayak flicker wenawa, seconds kihipayakata off wela aye on wenawa. Me location ekema same issue eka aye penuna.', 'Singlish', 'Lighting', 1, 1, 'High', 68.00, 'High', 'Awaiting Review', 0, 1, 1, '2026-08-25 20:45:00', '2026-08-25 20:45:02', NULL, NULL, NULL, '2026-08-25 20:45:00', '2026-08-29 13:38:14'),
(165, 'TCK-HF-260827-C-R120', 120, 3, 23, 37, 38, NULL, 'C-606', 'Small ceiling crack noticed', 'සිවිලිමේ කුඩා ඉරිතැලීමක් පෙනෙන අතර එය මෑතකදී වඩා පැහැදිලි වී ඇත. කරුණාකර පරීක්ෂා කරන්න.', 'Sinhala', 'Ceiling', 1, 12, 'High', 72.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-25 21:58:00', '2026-08-25 21:58:02', NULL, NULL, NULL, '2026-08-25 21:58:00', '2026-08-25 21:58:02'),
(166, 'TCK-HF-260827-C-R123', 123, 3, 10, 40, 26, NULL, 'C-101', 'නාන කාමරයේ ටැප් එකෙන් වතුර කාන්දු වෙනවා', 'නාන කාමරයේ ටැප් එක සම්පූර්ණයෙන් වැහුවත් වතුර කාන්දු වෙනවා. කරුණාකර ටැප් එක සහ පයිප් සම්බන්ධතාවය පරීක්ෂා කරන්න.', 'Sinhala', 'Tap', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-25 23:11:00', '2026-08-25 23:11:02', NULL, NULL, NULL, '2026-08-25 23:11:00', '2026-08-27 14:25:32'),
(167, 'TCK-HF-260827-C-R134', 134, 3, 31, 77, 14, NULL, 'C-903', 'AC eka cool karanne naha', 'AC eka run wenawa namuth room eka cool wenne naha. AC unit eka saha cooling system eka check karanna.', 'Singlish', 'Air Conditioner', 1, 4, 'Medium', 42.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-26 00:24:00', '2026-08-26 00:24:02', NULL, NULL, NULL, '2026-08-26 00:24:00', '2026-08-27 14:25:32'),
(168, 'TCK-HF-260827-C-R135', 135, 3, 34, 78, 53, NULL, 'C-1002', 'Common area needs cleaning', 'පොදු ප්‍රදේශයේ බිම මත දූවිලි සහ අපිරිසිදු දේ එකතු වී ඇති නිසා පිරිසිදු කිරීම අවශ්‍යයි.', 'Sinhala', 'Floor Surface', 1, 6, 'Low', 22.00, 'Low', 'Awaiting Review', 0, 0, 0, '2026-08-26 01:37:00', '2026-08-26 01:37:02', NULL, NULL, NULL, '2026-08-26 01:37:00', '2026-08-26 01:37:02'),
(169, 'TCK-HF-260827-C-R136', 136, 3, 40, 79, 29, NULL, 'C-1203', 'Bedroom door not closing properly', 'Bedroom door එක properly close වෙන්නේ නැහැ. Please check the hinges and frame.', 'Mixed', 'Door', 1, 8, 'Low', 25.00, 'Low', 'Awaiting Review', 0, 0, 0, '2026-08-26 02:50:00', '2026-08-26 02:50:02', NULL, NULL, NULL, '2026-08-26 02:50:00', '2026-08-26 02:50:02'),
(170, 'TCK-HF-260827-C-R137', 137, 3, 46, 80, 38, NULL, 'C-1404', 'Ceiling eke podi crack ekak penenawa', 'Ceiling eke podi crack ekak penenawa saha recently eka issarata wada clear wela wage. Please inspect karanna.', 'Singlish', 'Ceiling', 1, 12, 'High', 72.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-26 04:03:00', '2026-08-26 04:03:02', NULL, NULL, NULL, '2026-08-26 04:03:00', '2026-08-27 14:25:32'),
(171, 'TCK-HF-260827-C-R138', 138, 3, 51, 81, 80, NULL, 'C-1602', 'Lift stopping with unusual noise', 'Lift eka floor eke nawathinawata unusual saddayak enawa. Lift operation eka check karanna.', 'Singlish', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-26 05:16:00', '2026-08-26 05:16:02', NULL, NULL, NULL, '2026-08-26 05:16:00', '2026-08-26 05:16:02'),
(172, 'TCK-HF-260827-D-R091', 91, 4, 54, NULL, NULL, NULL, NULL, 'Lift making grinding noise at this floor', 'Lift eka me floor eke nawathinawata grinding wage saddayak enawa. Ada kihipa parakma eka una.', 'Singlish', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-26 06:29:00', '2026-08-26 06:29:02', NULL, NULL, NULL, '2026-08-26 06:29:00', '2026-08-26 06:29:02'),
(173, 'TCK-HF-260827-D-R094', 94, 4, 54, NULL, NULL, NULL, NULL, 'Lift making grinding noise at this floor - repeated report', 'ලිෆ්ට් එක මේ මහලේ නවත්වන විට ගැටෙන වගේ ශබ්දයක් එනවා. අද කිහිප වතාවක්ම මේ ශබ්දය ඇසුණා. මේ ස්ථානයේම එම ගැටලුව තවත් වරක් දක්නට ලැබුණා.', 'Sinhala', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 1, 1, '2026-08-26 07:42:00', '2026-08-26 07:42:02', NULL, NULL, NULL, '2026-08-26 07:42:00', '2026-08-26 07:42:02'),
(174, 'TCK-HF-260827-D-R099', 99, 4, 56, NULL, NULL, NULL, NULL, 'පොදු කොරිඩෝරයේ වතුර කාන්දුවක්', 'පොදු කොරිඩෝරයේ පයිප් එකකින් වතුර කාන්දු වෙනවා සහ ගමන් මාර්ගය අසල බිම තෙත් වෙනවා. කරුණාකර ඉක්මනින් පරීක්ෂා කරන්න.', 'Sinhala', 'Water Pipe', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-26 08:55:00', '2026-08-26 08:55:02', NULL, NULL, NULL, '2026-08-26 08:55:00', '2026-08-27 14:25:32'),
(175, 'TCK-HF-260827-D-R105', 105, 4, 56, NULL, 1030, NULL, NULL, 'Water leak in common corridor - repeated report', 'පොදු කොරිඩෝරයේ පයිප් එකකින් වතුර කාන්දු වෙනවා සහ ගමන් මාර්ගය අසල බිම තෙත් වෙනවා. මේ ස්ථානයේම එම ගැටලුව තවත් වරක් දක්නට ලැබුණා.', 'Sinhala', 'Water Pipe', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 1, 1, '2026-08-26 10:08:00', '2026-08-26 10:08:02', NULL, NULL, NULL, '2026-08-26 10:08:00', '2026-08-29 13:38:14'),
(176, 'TCK-HF-260827-D-R116', 116, 4, 55, NULL, 1029, NULL, NULL, 'Common corridor lights flickering', 'Common corridor එකේ lights කිහිපයක් flicker වෙනවා සහ seconds කිහිපයකට off වෙනවා.', 'Mixed', 'Lighting', 1, 1, 'High', 68.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-26 11:21:00', '2026-08-26 11:21:02', NULL, NULL, NULL, '2026-08-26 11:21:00', '2026-08-29 13:38:14'),
(177, 'TCK-HF-260827-D-R119', 119, 4, 55, NULL, 1029, NULL, NULL, 'Common corridor lights flicker wenawa - duplicate report', 'Common corridor eke lights kihipayak flicker wenawa, seconds kihipayakata off wela aye on wenawa. Me location ekema same issue eka thawa resident kenekuth report karala.', 'Singlish', 'Lighting', 1, 1, 'High', 68.00, 'High', 'Awaiting Review', 0, 1, 1, '2026-08-26 12:34:00', '2026-08-26 12:34:02', NULL, NULL, NULL, '2026-08-26 12:34:00', '2026-08-29 13:38:14'),
(178, 'TCK-HF-260827-D-R124', 124, 4, 58, 41, NULL, NULL, 'D-707', 'Drain water flowing slowly', 'Drain eken wathura godak himin bahinawa saha wathura ekathu wenawa. Block ekak thiyenawada check karanna.', 'Singlish', 'Drain', 1, 5, 'High', 62.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-26 13:47:00', '2026-08-26 13:47:02', NULL, NULL, NULL, '2026-08-26 13:47:00', '2026-08-26 13:47:02'),
(179, 'TCK-HF-260827-D-R139', 139, 4, 59, 82, NULL, NULL, 'D-802', 'Small ceiling crack noticed', 'සිවිලිමේ කුඩා ඉරිතැලීමක් පෙනෙන අතර එය මෑතකදී වඩා පැහැදිලි වී ඇත. කරුණාකර පරීක්ෂා කරන්න.', 'Sinhala', 'Ceiling', 1, 12, 'High', 72.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-26 15:00:00', '2026-08-26 15:00:02', NULL, NULL, NULL, '2026-08-26 15:00:00', '2026-08-26 15:00:02'),
(180, 'TCK-HF-260827-D-R140', 140, 4, 60, 83, NULL, NULL, 'D-903', 'Lift eka nawathinawata saddayak enawa', 'Lift eka floor eke nawathinawata unusual saddayak enawa. Lift operation eka check karanna.', 'Singlish', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-26 16:13:00', '2026-08-26 16:13:02', NULL, NULL, NULL, '2026-08-26 16:13:00', '2026-08-27 14:25:32'),
(181, 'TCK-HF-260827-D-R141', 141, 4, 61, 84, 764, NULL, 'D-1004', 'Bathroom tap leaking', 'Bathroom tap එක close කළත් water leak වෙනවා. Please check the tap and pipe connection.', 'Mixed', 'Tap', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-26 17:26:00', '2026-08-26 17:26:02', NULL, NULL, NULL, '2026-08-26 17:26:00', '2026-08-29 13:38:14'),
(182, 'TCK-HF-260827-D-R142', 142, 4, 57, 85, NULL, NULL, 'D-602', 'Drain water flowing slowly', 'Drain eken wathura godak himin bahinawa saha wathura ekathu wenawa. Block ekak thiyenawada check karanna.', 'Singlish', 'Drain', 1, 5, 'High', 62.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-26 18:39:00', '2026-08-26 18:39:02', NULL, NULL, NULL, '2026-08-26 18:39:00', '2026-08-26 18:39:02'),
(183, 'TCK-HF-260827-E-R088', 88, 7, 62, NULL, NULL, NULL, NULL, 'Lift making grinding noise at this floor', 'Lift එක මේ floor එකේ stop වෙනකොට grinding noise එකක් එනවා. අද කිහිප වතාවක්ම වුණා.', 'Mixed', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-26 19:52:00', '2026-08-26 19:52:02', NULL, NULL, NULL, '2026-08-26 19:52:00', '2026-08-26 19:52:02'),
(184, 'TCK-HF-260827-E-R102', 102, 7, 62, NULL, NULL, NULL, NULL, 'මේ මහලේ ලිෆ්ට් එකෙන් ගැටෙන වගේ ශබ්දයක් - නැවත පැමිණිල්ලක්', 'ලිෆ්ට් එක මේ මහලේ නවත්වන විට ගැටෙන වගේ ශබ්දයක් එනවා. අද කිහිප වතාවක්ම මේ ශබ්දය ඇසුණා. මේ ස්ථානයේම එම ගැටලුව තවත් නේවාසිකයෙකුත් වාර්තා කරලා තියෙනවා.', 'Sinhala', 'Lift', 1, 3, 'High', 64.00, 'High', 'Awaiting Review', 0, 1, 1, '2026-08-26 21:05:00', '2026-08-26 21:05:02', NULL, NULL, NULL, '2026-08-26 21:05:00', '2026-08-27 14:25:32'),
(185, 'TCK-HF-260827-E-R104', 104, 7, 67, NULL, 1041, NULL, NULL, 'Common corridor eke water leak ekak', 'Common corridor eke pipe ekakin wathura leak wenawa. Walkway eka langa floor eka wet wenawa. Please check karanna.', 'Singlish', 'Water Pipe', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-26 22:18:00', '2026-08-26 22:18:02', NULL, NULL, NULL, '2026-08-26 22:18:00', '2026-08-29 13:38:14'),
(186, 'TCK-HF-260827-E-R108', 108, 7, 67, NULL, 1041, NULL, NULL, 'Water leak in common corridor - repeated report', 'Common corridor එකේ pipe එකකින් water leak වෙනවා. Walkway එක ලඟ floor එක wet වෙලා. Same location එකේ මේ issue එක නැවතත් පේනවා.', 'Mixed', 'Water Pipe', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 1, 1, '2026-08-26 23:31:00', '2026-08-26 23:31:02', NULL, NULL, NULL, '2026-08-26 23:31:00', '2026-08-29 13:38:14'),
(187, 'TCK-HF-260827-E-R113', 113, 7, 65, NULL, 1039, NULL, NULL, 'Common corridor lights flickering', 'Common corridor eke lights kihipayak flicker wenawa, seconds kihipayakata off wela aye on wenawa.', 'Singlish', 'Lighting', 1, 1, 'High', 68.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-27 00:44:00', '2026-08-27 00:44:02', NULL, NULL, NULL, '2026-08-27 00:44:00', '2026-08-29 13:38:14'),
(188, 'TCK-HF-260827-E-R117', 117, 7, 65, NULL, 1039, NULL, NULL, 'Common corridor lights flickering - repeated report', 'පොදු කොරිඩෝරයේ ලයිට් කිහිපයක් දිලිසෙමින් තත්පර කිහිපයකට නිවී නැවත දැල්වෙනවා. මේ ස්ථානයේම එම ගැටලුව තවත් වරක් දක්නට ලැබුණා.', 'Sinhala', 'Lighting', 1, 1, 'High', 68.00, 'High', 'Awaiting Review', 0, 1, 1, '2026-08-27 01:57:00', '2026-08-27 01:57:02', NULL, NULL, NULL, '2026-08-27 01:57:00', '2026-08-29 13:38:14'),
(189, 'TCK-HF-260827-E-R122', 122, 7, 68, 39, 765, NULL, 'E-707', 'Bathroom tap leaking', 'නාන කාමරයේ ටැප් එක සම්පූර්ණයෙන් වැහුවත් වතුර කාන්දු වෙනවා. කරුණාකර ටැප් එක සහ පයිප් සම්බන්ධතාවය පරීක්ෂා කරන්න.', 'Sinhala', 'Tap', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-27 03:10:00', '2026-08-27 03:10:02', NULL, NULL, NULL, '2026-08-27 03:10:00', '2026-08-29 13:38:14'),
(190, 'TCK-HF-260827-E-R143', 143, 7, 69, 86, 765, NULL, 'E-802', 'Bathroom tap eka leak wenawa', 'Bathroom tap eka full close kalath wathura leak wenawa. Tap eka saha pipe connection eka check karanna.', 'Singlish', 'Tap', 1, 2, 'Medium', 48.00, 'Medium', 'Awaiting Review', 0, 0, 0, '2026-08-27 04:23:00', '2026-08-27 04:23:02', NULL, NULL, NULL, '2026-08-27 04:23:00', '2026-08-29 13:38:14'),
(191, 'TCK-HF-260827-E-R144', 144, 7, 70, 87, NULL, NULL, 'E-903', 'Drain water flowing slowly', 'ඩ්‍රේන් එකෙන් වතුර ඉතා හෙමින් බැස යන අතර වතුර එකතු වෙනවා. කරුණාකර අවහිරයක් තිබේද පරීක්ෂා කරන්න.', 'Sinhala', 'Drain', 1, 5, 'High', 62.00, 'High', 'Awaiting Review', 0, 0, 0, '2026-08-27 05:36:00', '2026-08-27 05:36:02', NULL, NULL, NULL, '2026-08-27 05:36:00', '2026-08-27 05:36:02'),
(192, 'TCK-HF-260827-E-R145', 145, 7, 71, 88, 797, NULL, 'E-1004', 'Pest activity in kitchen', 'Kitchen area එකේ evening time small cockroaches පේනවා. Please arrange pest control.', 'Mixed', 'Kitchen Area', 1, 7, 'Low', 28.00, 'Low', 'Awaiting Review', 0, 0, 0, '2026-08-27 06:49:00', '2026-08-27 06:49:02', NULL, NULL, NULL, '2026-08-27 06:49:00', '2026-08-29 13:38:14');
INSERT INTO `maintenance_tickets` (`ticket_id`, `ticket_number`, `resident_id`, `building_id`, `floor_id`, `unit_id`, `area_id`, `asset_id`, `unit_number_snapshot`, `subject`, `description`, `language_type`, `asset_type`, `contact_permission`, `current_category_id`, `current_priority`, `current_risk_score`, `current_risk_level`, `current_status`, `safety_flag`, `duplicate_flag`, `manual_review_required`, `submitted_at`, `analysed_at`, `resolved_at`, `closed_at`, `cancelled_at`, `created_at`, `updated_at`) VALUES
(193, 'TCK-HF-260827-E-R146', 146, 7, 72, 89, NULL, NULL, 'E-1102', 'Loose fitting needs repair', 'Apartment eke fitting ekak loose wela. Thawa damage wenna kalin eka secure karanna.', 'Singlish', 'General Fitting', 1, 9, 'Medium', 38.00, 'Medium', 'Accepted', 0, 0, 0, '2026-08-27 08:02:00', '2026-08-27 08:02:02', NULL, NULL, NULL, '2026-08-27 08:02:00', '2026-08-29 13:46:03'),
(194, 'TCK-260829-A760403F', 92, 1, 14, 9, 24, NULL, 'A-303', 'නාන කාමරයේ ජල නළය කැඩී ජලය ගලා යාම', 'නාන කාමරයේ බිත්තිය අසල තිබෙන ජල නළයක් කැඩී ගොස් විශාල ලෙස ජලය ගලා යනවා. ජලය බිම පුරා පැතිරෙමින් තිබෙන අතර පහළ මහලටත් ජලය යාමේ අවදානමක් තිබෙනවා. කරුණාකර ඉක්මනින් කාර්මිකයෙකු යොමු කරන්න', 'Mixed', 'Water Pipe', 0, 2, 'High', 54.70, 'Medium', 'In Progress', 0, 0, 0, '2026-08-29 10:31:11', '2026-08-29 10:31:14', NULL, NULL, NULL, '2026-08-29 10:31:11', '2026-08-29 10:36:11'),
(195, 'TCK-260829-DD29D052', 116, 4, 55, 33, 796, NULL, 'D-404', 'Kitchen eke plug point eka spark wenawa', 'Kitchen eke fridge eka connect karala thiyena plug point eken podi podi spark enawa. Samahara welawata burning smell ekakuth enawa. Plug eka use karanna baya hithenawa. Karunakarala ikmanata electrician kenek ewanna.', 'Singlish', 'Electrical Socket', 0, 1, 'Emergency', 100.00, 'Critical', 'Auto Assigned', 1, 0, 1, '2026-08-29 11:08:29', '2026-08-29 11:08:31', NULL, NULL, NULL, '2026-08-29 11:08:29', '2026-08-29 11:08:31'),
(196, 'TCK-260830-8887E2EA', 92, 1, 14, 9, 331, NULL, 'A-303', 'Lift eke door eka move wenakota open wenawa', 'Lift eka floors athara move wenakota door eka poddak open wenawa. Ada 4th floor eken yaddi door eka hariyata close wela nathiwa lift eka move una. Meka godak dangerous, kenekta accident ekak wenna puluwan. Ikmanata lift eka stop karala technician kenek ewanna.', 'Singlish', 'Passenger Lift', 0, 3, 'High', 62.70, 'High', 'Assigned', 0, 0, 0, '2026-08-30 00:27:49', '2026-08-30 00:28:43', NULL, NULL, NULL, '2026-08-30 00:27:49', '2026-08-30 00:29:12'),
(197, 'TCK-260830-D5AC82E9', 142, 4, 57, 85, 1031, NULL, 'D-602', 'Main electrical panel eke wires eliyata awilla', 'Corridor eke main electrical panel cover eka kadila wires eliyata penawa. Wires samahara than wala damage wela wage penawa, me thanin residents la godak yanawa. Danata spark ekak naha, namuth wires touch unoth electric shock ekak wenna puluwan. Ikmanata electrician kenek ewanna.', 'Singlish', 'Main Electrical Panel', 0, 1, 'Emergency', 100.00, 'Critical', 'Auto Assigned', 1, 0, 1, '2026-08-30 00:37:08', '2026-08-30 00:37:09', NULL, NULL, NULL, '2026-08-30 00:37:08', '2026-08-30 00:37:09'),
(198, 'TCK-260830-30BE14C5', 121, 2, 12, 38, 25, NULL, 'B-202', 'නාන කාමරයේ වතුර හීටරයෙන් විදුලි සැර වදිනවා', 'නාන කාමරයේ වතුර හීටරය on කළාම ටැප් එක සහ හීටරය අල්ලන විට විදුලි සැර වදිනවා. හීටරය අසලින් වතුරත් ලීක් වෙනවා. දැනට අපි හීටරය off කරලා තියෙනවා. මෙය අනතුරුදායක නිසා ඉක්මනින් විදුලි කාර්මිකයෙකු එවන්න.', 'Mixed', 'Water Heater', 0, 1, 'Emergency', 100.00, 'Critical', 'In Progress', 1, 0, 1, '2026-08-30 01:51:16', '2026-08-30 01:51:18', NULL, NULL, NULL, '2026-08-30 01:51:16', '2026-08-30 01:54:46'),
(199, 'TCK-260830-61E0D456', 146, 7, 72, 89, 777, NULL, 'E-1102', 'Main door lock eka kadila', 'Apartment eke main door lock eka completely broken. Door eka properly lock karanna baha, security issue ekak thiyenawa. Ikmanata repair karanna.', 'Singlish', 'Main Door Lock', 0, 13, 'High', 76.00, 'High', 'Assigned', 1, 0, 0, '2026-08-30 10:13:44', '2026-08-30 10:13:47', NULL, NULL, NULL, '2026-08-30 10:13:44', '2026-08-30 10:15:33'),
(200, 'TCK-260830-8B683F17', 122, 7, 68, 39, 795, NULL, 'E-707', 'Electrical room eke smoke saha burning smell enawa', 'Ground floor electrical room eken loku burning smell ekak saha podi smoke ekak enawa. Panel eka athule mokak hari overheat wela wage. Residents la e area eka langin yanawa, fire risk ekak thiyenna puluwan. Ikmanata electrician kenek assign karala check karanna.', 'Singlish', 'Main Distribution Panel', 0, 10, 'Emergency', 100.00, 'Critical', 'Auto Assigned', 1, 0, 1, '2026-08-30 10:22:03', '2026-08-30 10:22:04', NULL, NULL, NULL, '2026-08-30 10:22:03', '2026-08-30 10:22:04'),
(201, 'TCK-260830-8A3C97B0', 139, 4, 59, 82, 1033, NULL, 'D-802', 'කොරිඩෝවේ සිවිලිමෙන් විශාල වතුර කාන්දුවක්', '8 වන මහලේ කොරිඩෝවේ සිවිලිමෙන් විශාල වශයෙන් වතුර කාන්දු වෙනවා. වතුර බිමට ගලාගෙන යන අතර අසල ඇති විදුලි ලයිට් සහ වයර් තෙත් වෙමින් තියෙනවා. දැනට ගිනි පුපුරු හෝ දුමක් නැහැ, නමුත් විදුලි අනතුරක් ඇතිවෙන්න පුළුවන් නිසා ඉක්මනින් පරීක්ෂා කර අලුත්වැඩියා කරන්න.', 'Mixed', 'Ceiling Water Pipe', 0, 1, 'Emergency', 100.00, 'Critical', 'Accepted', 1, 0, 1, '2026-08-30 16:34:15', '2026-08-30 16:34:18', NULL, NULL, NULL, '2026-08-30 16:34:15', '2026-08-30 16:35:23');

--
-- Triggers `maintenance_tickets`
--
DELIMITER $$
CREATE TRIGGER `trg_ticket_number_before_insert` BEFORE INSERT ON `maintenance_tickets` FOR EACH ROW BEGIN
    IF NEW.ticket_number IS NULL OR TRIM(NEW.ticket_number) = '' THEN
        SET NEW.ticket_number = CONCAT(
            'TCK-',
            DATE_FORMAT(CURRENT_TIMESTAMP, '%y%m%d'),
            '-',
            UPPER(SUBSTRING(REPLACE(UUID(), '-', ''), 1, 8))
        );
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `model_versions`
--

CREATE TABLE `model_versions` (
  `model_version_id` bigint(20) UNSIGNED NOT NULL,
  `model_name` varchar(120) NOT NULL,
  `version` varchar(40) NOT NULL,
  `artifact_path` varchar(500) DEFAULT NULL,
  `metrics_json` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`metrics_json`)),
  `label_mapping_json` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`label_mapping_json`)),
  `training_data_version` varchar(80) DEFAULT NULL,
  `notes` varchar(500) DEFAULT NULL,
  `is_active` tinyint(1) NOT NULL DEFAULT 0,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `model_versions`
--

INSERT INTO `model_versions` (`model_version_id`, `model_name`, `version`, `artifact_path`, `metrics_json`, `label_mapping_json`, `training_data_version`, `notes`, `is_active`, `created_by`, `created_at`) VALUES
(19, 'HelaFixIt Multilingual Ticket Decision Bundle', '6.0.0', '../AI-model/Models/', '{\"category_accuracy\": 0.99451, \"category_macro_f1\": 0.99456, \"priority_accuracy\": 1.0, \"priority_macro_f1\": 1.0, \"dataset_rows\": 60000}', '{\"categories\": [\"Air Conditioning\", \"Carpentry\", \"Cleaning\", \"Drainage\", \"Electrical\", \"Fire and Safety\", \"Gas\", \"Lift\", \"Other\", \"Pest Control\", \"Plumbing\", \"Security and Access\", \"Structural\"], \"priorities\": [\"Emergency\", \"High\", \"Medium\", \"Low\"]}', 'multilingual-60k-residential-v6.0', 'Locally trained TF-IDF and Logistic Regression models used by the Flask application.', 1, NULL, '2026-08-17 12:06:25');

-- --------------------------------------------------------

--
-- Table structure for table `notifications`
--

CREATE TABLE `notifications` (
  `notification_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `ticket_id` bigint(20) UNSIGNED DEFAULT NULL,
  `event_type` varchar(80) NOT NULL,
  `channel` enum('In App','Email','SMS','Push','WhatsApp') NOT NULL DEFAULT 'In App',
  `title` varchar(180) NOT NULL,
  `message` varchar(1000) NOT NULL,
  `delivery_status` enum('Queued','Sent','Delivered','Failed','Read','Skipped') NOT NULL DEFAULT 'Queued',
  `provider_reference` varchar(255) DEFAULT NULL,
  `retry_count` smallint(5) UNSIGNED NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `sent_at` datetime DEFAULT NULL,
  `delivered_at` datetime DEFAULT NULL,
  `read_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `notifications`
--

INSERT INTO `notifications` (`notification_id`, `user_id`, `ticket_id`, `event_type`, `channel`, `title`, `message`, `delivery_status`, `provider_reference`, `retry_count`, `created_at`, `sent_at`, `delivered_at`, `read_at`) VALUES
(100, 335, 65, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-A-REV01 in Block A requires apartment admin attention.', 'Read', NULL, 0, '2026-08-23 14:05:02', '2026-08-23 14:05:02', '2026-08-23 14:05:02', '2026-08-24 23:03:17'),
(101, 335, 66, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-A-UNA01 in Block A requires apartment admin attention.', 'Read', NULL, 0, '2026-08-23 15:10:02', '2026-08-23 15:10:02', '2026-08-23 15:10:02', '2026-08-24 23:03:17'),
(102, 339, 70, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-B-REV01 in Block B requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 14:15:02', '2026-08-23 14:15:02', '2026-08-23 14:15:02', NULL),
(103, 339, 71, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-B-UNA01 in Block B requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 15:20:02', '2026-08-23 15:20:02', '2026-08-23 15:20:02', NULL),
(104, 336, 75, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-C-REV01 in Block C requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 14:25:02', '2026-08-23 14:25:02', '2026-08-23 14:25:02', NULL),
(105, 336, 76, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-C-UNA01 in Block C requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 15:30:02', '2026-08-23 15:30:02', '2026-08-23 15:30:02', NULL),
(106, 337, 80, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-D-REV01 in Block D requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 14:35:02', '2026-08-23 14:35:02', '2026-08-23 14:35:02', NULL),
(107, 337, 81, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-D-UNA01 in Block D requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 15:40:02', '2026-08-23 15:40:02', '2026-08-23 15:40:02', NULL),
(108, 338, 85, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-E-REV01 in Block E requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 14:45:02', '2026-08-23 14:45:02', '2026-08-23 14:45:02', NULL),
(109, 338, 86, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-E-UNA01 in Block E requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 15:50:02', '2026-08-23 15:50:02', '2026-08-23 15:50:02', NULL),
(110, 335, 90, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260820-A-REV02 in Block A requires apartment admin attention.', 'Read', NULL, 0, '2026-08-20 10:20:02', '2026-08-20 10:20:02', '2026-08-20 10:20:02', '2026-08-24 23:03:17'),
(111, 337, 91, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260820-D-UNA02 in Block D requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-20 11:15:02', '2026-08-20 11:15:02', '2026-08-20 11:15:02', NULL),
(115, 355, 67, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260823-A-ASG01 has been assigned to you in Block A.', 'Delivered', NULL, 0, '2026-08-23 09:00:00', '2026-08-23 09:00:00', '2026-08-23 09:00:00', NULL),
(116, 361, 68, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-A-PRG01 has been assigned to you in Block A.', 'Read', NULL, 0, '2026-08-22 15:15:00', '2026-08-22 15:15:00', '2026-08-22 15:15:00', '2026-08-22 15:40:00'),
(117, 375, 72, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260823-B-ASG01 has been assigned to you in Block B.', 'Delivered', NULL, 0, '2026-08-23 09:10:00', '2026-08-23 09:10:00', '2026-08-23 09:10:00', NULL),
(118, 409, 73, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-B-PRG01 has been assigned to you in Block B.', 'Read', NULL, 0, '2026-08-22 15:25:00', '2026-08-22 15:25:00', '2026-08-22 15:25:00', '2026-08-22 15:45:00'),
(119, 380, 77, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260823-C-ASG01 has been assigned to you in Block C.', 'Delivered', NULL, 0, '2026-08-23 09:20:00', '2026-08-23 09:20:00', '2026-08-23 09:20:00', NULL),
(120, 354, 78, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-C-PRG01 has been assigned to you in Block C.', 'Read', NULL, 0, '2026-08-22 15:40:00', '2026-08-22 15:40:00', '2026-08-22 15:40:00', '2026-08-22 16:00:00'),
(121, 414, 82, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260823-D-ASG01 has been assigned to you in Block D.', 'Delivered', NULL, 0, '2026-08-23 09:30:00', '2026-08-23 09:30:00', '2026-08-23 09:30:00', NULL),
(122, 352, 83, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-D-PRG01 has been assigned to you in Block D.', 'Read', NULL, 0, '2026-08-22 15:55:00', '2026-08-22 15:55:00', '2026-08-22 15:55:00', '2026-08-22 16:15:00'),
(123, 368, 87, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260823-E-ASG01 has been assigned to you in Block E.', 'Delivered', NULL, 0, '2026-08-23 09:40:00', '2026-08-23 09:40:00', '2026-08-23 09:40:00', NULL),
(124, 410, 88, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-E-PRG01 has been assigned to you in Block E.', 'Read', NULL, 0, '2026-08-22 16:10:00', '2026-08-22 16:10:00', '2026-08-22 16:10:00', '2026-08-22 16:30:00'),
(125, 381, 92, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260820-E-ASG02 has been assigned to you in Block E.', 'Delivered', NULL, 0, '2026-08-20 09:50:00', '2026-08-20 09:50:00', '2026-08-20 09:50:00', NULL),
(130, 335, 96, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-ML001 in Block A requires apartment admin attention.', 'Read', NULL, 0, '2026-08-23 13:00:02', '2026-08-23 13:00:02', '2026-08-23 13:00:02', '2026-08-24 23:03:17'),
(131, 335, 97, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-ML002 in Block A requires apartment admin attention.', 'Read', NULL, 0, '2026-08-23 13:17:02', '2026-08-23 13:17:02', '2026-08-23 13:17:02', '2026-08-24 23:03:17'),
(132, 335, 98, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-ML003 in Block A requires apartment admin attention.', 'Read', NULL, 0, '2026-08-23 13:34:02', '2026-08-23 13:34:02', '2026-08-23 13:34:02', '2026-08-24 23:03:17'),
(133, 335, 99, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-ML004 in Block A requires apartment admin attention.', 'Read', NULL, 0, '2026-08-23 13:51:02', '2026-08-23 13:51:02', '2026-08-23 13:51:02', '2026-08-24 23:03:17'),
(134, 335, 100, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-ML005 in Block A requires apartment admin attention.', 'Read', NULL, 0, '2026-08-23 14:08:02', '2026-08-23 14:08:02', '2026-08-23 14:08:02', '2026-08-24 23:03:17'),
(135, 335, 101, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-ML006 in Block A requires apartment admin attention.', 'Read', NULL, 0, '2026-08-23 14:25:02', '2026-08-23 14:25:02', '2026-08-23 14:25:02', '2026-08-24 23:03:17'),
(136, 335, 102, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-ML007 in Block A requires apartment admin attention.', 'Read', NULL, 0, '2026-08-23 14:42:02', '2026-08-23 14:42:02', '2026-08-23 14:42:02', '2026-08-24 23:03:17'),
(137, 339, 103, 'Ticket Review Required', 'In App', 'Ticket needs admin review', 'TCK-HF-260823-ML008 in Block B requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 14:59:02', '2026-08-23 14:59:02', '2026-08-23 14:59:02', NULL),
(138, 339, 104, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-ML009 in Block B requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 17:00:02', '2026-08-23 17:00:02', '2026-08-23 17:00:02', NULL),
(139, 339, 105, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-ML010 in Block B requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 17:17:02', '2026-08-23 17:17:02', '2026-08-23 17:17:02', NULL),
(140, 339, 106, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-ML011 in Block B requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 17:34:02', '2026-08-23 17:34:02', '2026-08-23 17:34:02', NULL),
(141, 339, 107, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-ML012 in Block B requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 17:51:02', '2026-08-23 17:51:02', '2026-08-23 17:51:02', NULL),
(142, 339, 108, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-ML013 in Block B requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 18:08:02', '2026-08-23 18:08:02', '2026-08-23 18:08:02', NULL),
(143, 339, 109, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-ML014 in Block B requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 18:25:02', '2026-08-23 18:25:02', '2026-08-23 18:25:02', NULL),
(144, 339, 110, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-ML015 in Block B requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 18:42:02', '2026-08-23 18:42:02', '2026-08-23 18:42:02', NULL),
(145, 336, 111, 'Emergency Unassigned', 'In App', 'Urgent ticket needs assignment', 'TCK-HF-260823-ML016 in Block C requires apartment admin attention.', 'Delivered', NULL, 0, '2026-08-23 18:59:02', '2026-08-23 18:59:02', '2026-08-23 18:59:02', NULL),
(161, 380, 118, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-ML023 has been assigned to you in Block C.', 'Delivered', NULL, 0, '2026-08-22 10:20:00', '2026-08-22 10:20:00', '2026-08-22 10:20:00', NULL),
(162, 356, 112, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-ML017 has been assigned to you in Block C.', 'Delivered', NULL, 0, '2026-08-22 08:38:00', '2026-08-22 08:38:00', '2026-08-22 08:38:00', NULL),
(163, 369, 113, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-ML018 has been assigned to you in Block C.', 'Delivered', NULL, 0, '2026-08-22 08:55:00', '2026-08-22 08:55:00', '2026-08-22 08:55:00', NULL),
(164, 387, 114, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-ML019 has been assigned to you in Block C.', 'Delivered', NULL, 0, '2026-08-22 09:12:00', '2026-08-22 09:12:00', '2026-08-22 09:12:00', NULL),
(165, 350, 115, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-ML020 has been assigned to you in Block C.', 'Delivered', NULL, 0, '2026-08-22 09:29:00', '2026-08-22 09:29:00', '2026-08-22 09:29:00', NULL),
(166, 378, 116, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-ML021 has been assigned to you in Block C.', 'Delivered', NULL, 0, '2026-08-22 09:46:00', '2026-08-22 09:46:00', '2026-08-22 09:46:00', NULL),
(167, 386, 117, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-ML022 has been assigned to you in Block C.', 'Delivered', NULL, 0, '2026-08-22 10:03:00', '2026-08-22 10:03:00', '2026-08-22 10:03:00', NULL),
(168, 408, 119, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260822-ML024 has been assigned to you in Block D.', 'Delivered', NULL, 0, '2026-08-22 10:37:00', '2026-08-22 10:37:00', '2026-08-22 10:37:00', NULL),
(169, 402, 120, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260821-ML025 has been assigned to you in Block D.', 'Read', NULL, 0, '2026-08-21 09:38:00', '2026-08-21 09:38:00', '2026-08-21 09:38:00', '2026-08-21 09:47:00'),
(170, 366, 121, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260821-ML026 has been assigned to you in Block D.', 'Read', NULL, 0, '2026-08-21 09:55:00', '2026-08-21 09:55:00', '2026-08-21 09:55:00', '2026-08-21 10:04:00'),
(171, 412, 122, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260821-ML027 has been assigned to you in Block D.', 'Read', NULL, 0, '2026-08-21 10:12:00', '2026-08-21 10:12:00', '2026-08-21 10:12:00', '2026-08-21 10:21:00'),
(172, 364, 123, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260821-ML028 has been assigned to you in Block D.', 'Read', NULL, 0, '2026-08-21 10:29:00', '2026-08-21 10:29:00', '2026-08-21 10:29:00', '2026-08-21 10:38:00'),
(173, 414, 124, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260821-ML029 has been assigned to you in Block D.', 'Read', NULL, 0, '2026-08-21 10:46:00', '2026-08-21 10:46:00', '2026-08-21 10:46:00', '2026-08-21 10:55:00'),
(174, 413, 125, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260821-ML030 has been assigned to you in Block D.', 'Read', NULL, 0, '2026-08-21 11:03:00', '2026-08-21 11:03:00', '2026-08-21 11:03:00', '2026-08-21 11:12:00'),
(175, 373, 126, 'Job Assigned', 'In App', 'Maintenance job assigned', 'TCK-HF-260821-ML031 has been assigned to you in Block E.', 'Read', NULL, 0, '2026-08-21 11:20:00', '2026-08-21 11:20:00', '2026-08-21 11:20:00', '2026-08-21 11:29:00'),
(176, 300, 133, 'Ticket Created', 'In App', 'Maintenance ticket received', 'TCK-260826-140CCD38 was saved successfully and local AI analysis has started.', 'Read', NULL, 0, '2026-08-26 18:44:33', '2026-08-26 18:44:33', '2026-08-26 18:44:33', '2026-08-26 19:02:50'),
(177, 300, 133, 'AI Analysis', 'In App', 'Ticket analysis completed', 'TCK-260826-140CCD38 was analysed as Plumbing with High priority and risk 53.2/100.', 'Read', NULL, 0, '2026-08-26 18:44:35', '2026-08-26 18:44:35', '2026-08-26 18:44:35', '2026-08-26 19:02:50'),
(178, 336, 133, 'AI Analysis', 'In App', 'AI ticket review ready', 'TCK-260826-140CCD38 analysed as Plumbing / High / risk 53.2.', 'Delivered', NULL, 0, '2026-08-26 18:44:35', '2026-08-26 18:44:35', '2026-08-26 18:44:35', NULL),
(179, 340, 133, 'AI Analysis', 'In App', 'AI ticket review ready', 'TCK-260826-140CCD38 analysed as Plumbing / High / risk 53.2.', 'Delivered', NULL, 0, '2026-08-26 18:44:35', '2026-08-26 18:44:35', '2026-08-26 18:44:35', NULL),
(180, 300, 133, 'Ticket Assignment', 'In App', 'Technician assigned', 'TCK-260826-140CCD38 was assigned to Indika Jayawardena.', 'Read', NULL, 0, '2026-08-26 18:57:50', '2026-08-26 18:57:50', '2026-08-26 18:57:50', '2026-08-26 19:02:50'),
(181, 369, 133, 'Ticket Assignment', 'In App', 'New maintenance job', 'TCK-260826-140CCD38 has been assigned to you.', 'Delivered', NULL, 0, '2026-08-26 18:57:50', '2026-08-26 18:57:50', '2026-08-26 18:57:50', NULL),
(182, 300, 133, 'Status Changed', 'In App', 'Ticket status updated', 'TCK-260826-140CCD38 status changed to Accepted.', 'Read', NULL, 0, '2026-08-26 18:59:04', '2026-08-26 18:59:04', '2026-08-26 18:59:04', '2026-08-26 19:02:50'),
(183, 300, 133, 'Status Changed', 'In App', 'Ticket status updated', 'TCK-260826-140CCD38 status changed to In Progress.', 'Read', NULL, 0, '2026-08-26 19:00:09', '2026-08-26 19:00:09', '2026-08-26 19:00:09', '2026-08-26 19:02:50'),
(184, 300, 133, 'Ticket Completed', 'In App', 'Maintenance work resolved', 'TCK-260826-140CCD38 was marked resolved by the assigned technician.', 'Read', NULL, 0, '2026-08-26 19:02:08', '2026-08-26 19:02:08', '2026-08-26 19:02:08', '2026-08-26 19:02:50'),
(185, 277, 194, 'Ticket Created', 'In App', 'Maintenance ticket received', 'TCK-260829-A760403F was saved successfully and local AI analysis has started.', 'Delivered', NULL, 0, '2026-08-29 10:31:11', '2026-08-29 10:31:11', '2026-08-29 10:31:11', NULL),
(186, 277, 194, 'AI Analysis', 'In App', 'Ticket analysis completed', 'TCK-260829-A760403F was analysed as Plumbing with High priority and risk 54.7/100.', 'Delivered', NULL, 0, '2026-08-29 10:31:14', '2026-08-29 10:31:14', '2026-08-29 10:31:14', NULL),
(187, 335, 194, 'AI Analysis', 'In App', 'AI ticket review ready', 'TCK-260829-A760403F analysed as Plumbing / High / risk 54.7.', 'Delivered', NULL, 0, '2026-08-29 10:31:14', '2026-08-29 10:31:14', '2026-08-29 10:31:14', NULL),
(188, 341, 194, 'AI Analysis', 'In App', 'AI ticket review ready', 'TCK-260829-A760403F analysed as Plumbing / High / risk 54.7.', 'Delivered', NULL, 0, '2026-08-29 10:31:14', '2026-08-29 10:31:14', '2026-08-29 10:31:14', NULL),
(189, 277, 194, 'Ticket Assignment', 'In App', 'Technician assigned', 'TCK-260829-A760403F was assigned to Isuru Madushan.', 'Delivered', NULL, 0, '2026-08-29 10:32:58', '2026-08-29 10:32:58', '2026-08-29 10:32:58', NULL),
(190, 371, 194, 'Ticket Assignment', 'In App', 'New maintenance job', 'TCK-260829-A760403F has been assigned to you.', 'Delivered', NULL, 0, '2026-08-29 10:32:58', '2026-08-29 10:32:58', '2026-08-29 10:32:58', NULL),
(191, 277, 194, 'Status Changed', 'In App', 'Ticket status updated', 'TCK-260829-A760403F status changed to Accepted.', 'Delivered', NULL, 0, '2026-08-29 10:34:13', '2026-08-29 10:34:13', '2026-08-29 10:34:13', NULL),
(192, 277, 194, 'Status Changed', 'In App', 'Ticket status updated', 'TCK-260829-A760403F status changed to In Progress.', 'Delivered', NULL, 0, '2026-08-29 10:36:11', '2026-08-29 10:36:11', '2026-08-29 10:36:11', NULL),
(193, 301, 195, 'Ticket Created', 'In App', 'Maintenance ticket received', 'TCK-260829-DD29D052 was saved successfully and local AI analysis has started.', 'Delivered', NULL, 0, '2026-08-29 11:08:29', '2026-08-29 11:08:29', '2026-08-29 11:08:29', NULL),
(194, 402, 195, 'Emergency Assignment', 'In App', 'Emergency maintenance job', 'TCK-260829-DD29D052 was automatically assigned to you as an emergency job.', 'Delivered', NULL, 0, '2026-08-29 11:08:31', '2026-08-29 11:08:31', '2026-08-29 11:08:31', NULL),
(195, 301, 195, 'AI Analysis', 'In App', 'Ticket analysis completed', 'TCK-260829-DD29D052 was analysed as Electrical with Emergency priority and risk 100.0/100.', 'Delivered', NULL, 0, '2026-08-29 11:08:31', '2026-08-29 11:08:31', '2026-08-29 11:08:31', NULL),
(196, 337, 195, 'Emergency AI Analysis', 'In App', 'Emergency ticket requires attention', 'TCK-260829-DD29D052 analysed as Electrical / Emergency / risk 100.0. Auto assigned to Sampath Perera.', 'Delivered', NULL, 0, '2026-08-29 11:08:31', '2026-08-29 11:08:31', '2026-08-29 11:08:31', NULL),
(197, 343, 195, 'Emergency AI Analysis', 'In App', 'Emergency ticket requires attention', 'TCK-260829-DD29D052 analysed as Electrical / Emergency / risk 100.0. Auto assigned to Sampath Perera.', 'Delivered', NULL, 0, '2026-08-29 11:08:31', '2026-08-29 11:08:31', '2026-08-29 11:08:31', NULL),
(198, 505, 193, 'Ticket Assignment', 'In App', 'Technician assigned', 'TCK-HF-260827-E-R146 was assigned to Pubudu Peiris.', 'Delivered', NULL, 0, '2026-08-29 13:45:04', NULL, NULL, NULL),
(199, 393, 193, 'Ticket Assignment', 'In App', 'New maintenance job', 'TCK-HF-260827-E-R146 has been assigned to you.', 'Delivered', NULL, 0, '2026-08-29 13:45:04', NULL, NULL, NULL),
(200, 505, 193, 'Status Changed', 'In App', 'Ticket status updated', 'TCK-HF-260827-E-R146 status changed to Accepted.', 'Delivered', NULL, 0, '2026-08-29 13:46:03', NULL, NULL, NULL),
(201, 506, NULL, 'Registration Approved', 'In App', 'Resident account approved', 'Your resident account has been approved. You can now sign in.', 'Delivered', NULL, 0, '2026-08-29 14:04:27', NULL, NULL, NULL),
(202, 335, NULL, 'Registration Request', 'In App', 'Resident registration request', 'Rakindu Fernando requested a resident account for Block A.', 'Delivered', NULL, 0, '2026-08-29 14:09:52', NULL, NULL, NULL),
(203, 341, NULL, 'Registration Request', 'In App', 'Resident registration request', 'Rakindu Fernando requested a resident account for Block A.', 'Delivered', NULL, 0, '2026-08-29 14:09:52', NULL, NULL, NULL),
(204, 15, NULL, 'Registration Request', 'In App', 'Resident registration request', 'Rakindu Fernando requested a resident account for Block A.', 'Read', NULL, 0, '2026-08-29 14:09:52', NULL, NULL, '2026-08-29 18:34:39'),
(205, 477, NULL, 'Registration Request', 'In App', 'Resident registration request', 'Rakindu Fernando requested a resident account for Block A.', 'Delivered', NULL, 0, '2026-08-29 14:09:52', NULL, NULL, NULL),
(206, 478, NULL, 'Registration Request', 'In App', 'Resident registration request', 'Rakindu Fernando requested a resident account for Block A.', 'Delivered', NULL, 0, '2026-08-29 14:09:52', NULL, NULL, NULL),
(207, 479, NULL, 'Registration Request', 'In App', 'Resident registration request', 'Rakindu Fernando requested a resident account for Block A.', 'Delivered', NULL, 0, '2026-08-29 14:09:52', NULL, NULL, NULL),
(208, 480, NULL, 'Registration Request', 'In App', 'Resident registration request', 'Rakindu Fernando requested a resident account for Block A.', 'Delivered', NULL, 0, '2026-08-29 14:09:52', NULL, NULL, NULL),
(209, 481, NULL, 'Registration Request', 'In App', 'Resident registration request', 'Rakindu Fernando requested a resident account for Block A.', 'Delivered', NULL, 0, '2026-08-29 14:09:52', NULL, NULL, NULL),
(210, 482, NULL, 'Registration Request', 'In App', 'Resident registration request', 'Rakindu Fernando requested a resident account for Block A.', 'Delivered', NULL, 0, '2026-08-29 14:09:52', NULL, NULL, NULL),
(211, 483, NULL, 'Registration Request', 'In App', 'Resident registration request', 'Rakindu Fernando requested a resident account for Block A.', 'Delivered', NULL, 0, '2026-08-29 14:09:52', NULL, NULL, NULL),
(217, 507, NULL, 'Registration Approved', 'In App', 'Resident account approved', 'Your resident account has been approved. You can now sign in.', 'Delivered', NULL, 0, '2026-08-29 14:10:46', NULL, NULL, NULL),
(218, 15, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:17:28', NULL, NULL, '2026-08-30 01:18:20'),
(219, 477, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:17:28', NULL, NULL, '2026-08-30 01:18:20'),
(220, 478, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:17:28', NULL, NULL, '2026-08-30 01:18:20'),
(221, 479, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:17:28', NULL, NULL, '2026-08-30 01:18:20'),
(222, 480, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:17:28', NULL, NULL, '2026-08-30 01:18:20'),
(223, 481, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:17:28', NULL, NULL, '2026-08-30 01:18:20'),
(224, 482, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:17:28', NULL, NULL, '2026-08-30 01:18:20'),
(225, 483, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:17:28', NULL, NULL, '2026-08-30 01:18:20'),
(233, 277, 196, 'Ticket Created', 'In App', 'Maintenance ticket received', 'TCK-260830-8887E2EA was saved successfully and local AI analysis has started.', 'Delivered', NULL, 0, '2026-08-30 00:27:49', NULL, NULL, NULL),
(234, 277, 196, 'AI Analysis', 'In App', 'Ticket analysis completed', 'TCK-260830-8887E2EA was analysed as Lift with High priority and risk 62.7/100.', 'Delivered', NULL, 0, '2026-08-30 00:27:53', NULL, NULL, NULL),
(235, 335, 196, 'AI Analysis', 'In App', 'AI ticket review ready', 'TCK-260830-8887E2EA analysed as Lift / High / risk 62.7.', 'Delivered', NULL, 0, '2026-08-30 00:27:53', NULL, NULL, NULL),
(236, 341, 196, 'AI Analysis', 'In App', 'AI ticket review ready', 'TCK-260830-8887E2EA analysed as Lift / High / risk 62.7.', 'Delivered', NULL, 0, '2026-08-30 00:27:53', NULL, NULL, NULL),
(237, 277, 196, 'AI Analysis', 'In App', 'Ticket analysis completed', 'TCK-260830-8887E2EA was analysed as Lift with High priority and risk 62.7/100.', 'Delivered', NULL, 0, '2026-08-30 00:28:43', NULL, NULL, NULL),
(238, 335, 196, 'AI Analysis', 'In App', 'AI ticket review ready', 'TCK-260830-8887E2EA analysed as Lift / High / risk 62.7.', 'Delivered', NULL, 0, '2026-08-30 00:28:43', NULL, NULL, NULL),
(239, 341, 196, 'AI Analysis', 'In App', 'AI ticket review ready', 'TCK-260830-8887E2EA analysed as Lift / High / risk 62.7.', 'Delivered', NULL, 0, '2026-08-30 00:28:43', NULL, NULL, NULL),
(240, 277, 196, 'Ticket Assignment', 'In App', 'Technician assigned', 'TCK-260830-8887E2EA was assigned to Supun Jayasinghe.', 'Delivered', NULL, 0, '2026-08-30 00:29:12', NULL, NULL, NULL),
(241, 404, 196, 'Ticket Assignment', 'In App', 'New maintenance job', 'TCK-260830-8887E2EA has been assigned to you.', 'Delivered', NULL, 0, '2026-08-30 00:29:12', NULL, NULL, NULL),
(242, 501, 197, 'Ticket Created', 'In App', 'Maintenance ticket received', 'TCK-260830-D5AC82E9 was saved successfully and local AI analysis has started.', 'Delivered', NULL, 0, '2026-08-30 00:37:08', NULL, NULL, NULL),
(243, 402, 197, 'Emergency Assignment', 'In App', 'Emergency maintenance job', 'TCK-260830-D5AC82E9 was automatically assigned to you as an emergency job.', 'Delivered', NULL, 0, '2026-08-30 00:37:09', NULL, NULL, NULL),
(244, 501, 197, 'AI Analysis', 'In App', 'Ticket analysis completed', 'TCK-260830-D5AC82E9 was analysed as Electrical with Emergency priority and risk 100.0/100.', 'Delivered', NULL, 0, '2026-08-30 00:37:09', NULL, NULL, NULL),
(245, 337, 197, 'Emergency AI Analysis', 'In App', 'Emergency ticket requires attention', 'TCK-260830-D5AC82E9 analysed as Electrical / Emergency / risk 100.0. Auto assigned to Sampath Perera.', 'Delivered', NULL, 0, '2026-08-30 00:37:09', NULL, NULL, NULL),
(246, 343, 197, 'Emergency AI Analysis', 'In App', 'Emergency ticket requires attention', 'TCK-260830-D5AC82E9 analysed as Electrical / Emergency / risk 100.0. Auto assigned to Sampath Perera.', 'Delivered', NULL, 0, '2026-08-30 00:37:09', NULL, NULL, NULL),
(247, 15, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for thilini.abeysekara@hotmail.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:57:11', NULL, NULL, '2026-08-30 01:42:42'),
(248, 477, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for thilini.abeysekara@hotmail.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:57:11', NULL, NULL, '2026-08-30 01:42:42'),
(249, 478, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for thilini.abeysekara@hotmail.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:57:11', NULL, NULL, '2026-08-30 01:42:42'),
(250, 479, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for thilini.abeysekara@hotmail.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:57:11', NULL, NULL, '2026-08-30 01:42:42'),
(251, 480, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for thilini.abeysekara@hotmail.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:57:11', NULL, NULL, '2026-08-30 01:42:42'),
(252, 481, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for thilini.abeysekara@hotmail.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:57:11', NULL, NULL, '2026-08-30 01:42:42'),
(253, 482, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for thilini.abeysekara@hotmail.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:57:11', NULL, NULL, '2026-08-30 01:42:42'),
(254, 483, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for thilini.abeysekara@hotmail.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 00:57:11', NULL, NULL, '2026-08-30 01:42:42'),
(262, 15, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 01:08:27', NULL, NULL, '2026-08-30 01:18:20'),
(263, 477, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 01:08:27', NULL, NULL, '2026-08-30 01:18:20'),
(264, 478, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 01:08:27', NULL, NULL, '2026-08-30 01:18:20'),
(265, 479, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 01:08:27', NULL, NULL, '2026-08-30 01:18:20'),
(266, 480, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 01:08:27', NULL, NULL, '2026-08-30 01:18:20'),
(267, 481, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 01:08:27', NULL, NULL, '2026-08-30 01:18:20'),
(268, 482, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 01:08:27', NULL, NULL, '2026-08-30 01:18:20'),
(269, 483, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 01:08:27', NULL, NULL, '2026-08-30 01:18:20'),
(277, 306, 198, 'Ticket Created', 'In App', 'Maintenance ticket received', 'TCK-260830-30BE14C5 was saved successfully and local AI analysis has started.', 'Delivered', NULL, 0, '2026-08-30 01:51:16', NULL, NULL, NULL),
(278, 365, 198, 'Emergency Assignment', 'In App', 'Emergency maintenance job', 'TCK-260830-30BE14C5 was automatically assigned to you as an emergency job.', 'Delivered', NULL, 0, '2026-08-30 01:51:18', NULL, NULL, NULL),
(279, 306, 198, 'AI Analysis', 'In App', 'Ticket analysis completed', 'TCK-260830-30BE14C5 was analysed as Electrical with Emergency priority and risk 100.0/100.', 'Delivered', NULL, 0, '2026-08-30 01:51:18', NULL, NULL, NULL),
(280, 339, 198, 'Emergency AI Analysis', 'In App', 'Emergency ticket requires attention', 'TCK-260830-30BE14C5 analysed as Electrical / Emergency / risk 100.0. Auto assigned to Gayan Perera.', 'Delivered', NULL, 0, '2026-08-30 01:51:18', NULL, NULL, NULL),
(281, 344, 198, 'Emergency AI Analysis', 'In App', 'Emergency ticket requires attention', 'TCK-260830-30BE14C5 analysed as Electrical / Emergency / risk 100.0. Auto assigned to Gayan Perera.', 'Delivered', NULL, 0, '2026-08-30 01:51:18', NULL, NULL, NULL),
(282, 306, 198, 'Status Changed', 'In App', 'Ticket status updated', 'TCK-260830-30BE14C5 status changed to Accepted.', 'Delivered', NULL, 0, '2026-08-30 01:54:18', NULL, NULL, NULL),
(283, 306, 198, 'Status Changed', 'In App', 'Ticket status updated', 'TCK-260830-30BE14C5 status changed to In Progress.', 'Delivered', NULL, 0, '2026-08-30 01:54:46', NULL, NULL, NULL),
(284, 15, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for hasini.fernando@gmail.com. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 08:45:01', NULL, NULL, NULL),
(285, 477, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for hasini.fernando@gmail.com. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 08:45:01', NULL, NULL, NULL),
(286, 478, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for hasini.fernando@gmail.com. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 08:45:01', NULL, NULL, NULL),
(287, 479, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for hasini.fernando@gmail.com. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 08:45:01', NULL, NULL, NULL),
(288, 480, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for hasini.fernando@gmail.com. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 08:45:01', NULL, NULL, NULL),
(289, 481, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for hasini.fernando@gmail.com. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 08:45:01', NULL, NULL, NULL),
(290, 482, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for hasini.fernando@gmail.com. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 08:45:01', NULL, NULL, NULL),
(291, 483, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for hasini.fernando@gmail.com. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 08:45:01', NULL, NULL, NULL),
(299, 15, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 10:03:48', NULL, NULL, '2026-08-30 10:05:24'),
(300, 477, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 10:03:48', NULL, NULL, '2026-08-30 10:05:24'),
(301, 478, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 10:03:48', NULL, NULL, '2026-08-30 10:05:24'),
(302, 479, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 10:03:48', NULL, NULL, '2026-08-30 10:05:24'),
(303, 480, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 10:03:48', NULL, NULL, '2026-08-30 10:05:24'),
(304, 481, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 10:03:48', NULL, NULL, '2026-08-30 10:05:24'),
(305, 482, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 10:03:48', NULL, NULL, '2026-08-30 10:05:24'),
(306, 483, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for dinuka.nawaratne@yahoo.com. Verify the account and issue a temporary password from User Management.', 'Read', NULL, 0, '2026-08-30 10:03:48', NULL, NULL, '2026-08-30 10:05:24'),
(314, 505, 199, 'Ticket Created', 'In App', 'Maintenance ticket received', 'TCK-260830-61E0D456 was saved successfully and local AI analysis has started.', 'Delivered', NULL, 0, '2026-08-30 10:13:44', NULL, NULL, NULL),
(315, 505, 199, 'AI Analysis', 'In App', 'Ticket analysis completed', 'TCK-260830-61E0D456 was analysed as Security and Access with High priority and risk 76.0/100.', 'Delivered', NULL, 0, '2026-08-30 10:13:47', NULL, NULL, NULL),
(316, 338, 199, 'AI Analysis', 'In App', 'AI ticket review ready', 'TCK-260830-61E0D456 analysed as Security and Access / High / risk 76.0.', 'Delivered', NULL, 0, '2026-08-30 10:13:47', NULL, NULL, NULL),
(317, 342, 199, 'AI Analysis', 'In App', 'AI ticket review ready', 'TCK-260830-61E0D456 analysed as Security and Access / High / risk 76.0.', 'Delivered', NULL, 0, '2026-08-30 10:13:47', NULL, NULL, NULL),
(318, 505, 199, 'Ticket Assignment', 'In App', 'Technician assigned', 'TCK-260830-61E0D456 was assigned to Udaya Samarasinghe.', 'Delivered', NULL, 0, '2026-08-30 10:15:33', NULL, NULL, NULL),
(319, 410, 199, 'Ticket Assignment', 'In App', 'New maintenance job', 'TCK-260830-61E0D456 has been assigned to you.', 'Delivered', NULL, 0, '2026-08-30 10:15:33', NULL, NULL, NULL),
(320, 307, 200, 'Ticket Created', 'In App', 'Maintenance ticket received', 'TCK-260830-8B683F17 was saved successfully and local AI analysis has started.', 'Delivered', NULL, 0, '2026-08-30 10:22:03', NULL, NULL, NULL),
(321, 395, 200, 'Emergency Assignment', 'In App', 'Emergency maintenance job', 'TCK-260830-8B683F17 was automatically assigned to you as an emergency job.', 'Delivered', NULL, 0, '2026-08-30 10:22:04', NULL, NULL, NULL),
(322, 307, 200, 'AI Analysis', 'In App', 'Ticket analysis completed', 'TCK-260830-8B683F17 was analysed as Fire and Safety with Emergency priority and risk 100.0/100.', 'Delivered', NULL, 0, '2026-08-30 10:22:04', NULL, NULL, NULL),
(323, 338, 200, 'Emergency AI Analysis', 'In App', 'Emergency ticket requires attention', 'TCK-260830-8B683F17 analysed as Fire and Safety / Emergency / risk 100.0. Auto assigned to Ravimal Herath.', 'Delivered', NULL, 0, '2026-08-30 10:22:04', NULL, NULL, NULL),
(324, 342, 200, 'Emergency AI Analysis', 'In App', 'Emergency ticket requires attention', 'TCK-260830-8B683F17 analysed as Fire and Safety / Emergency / risk 100.0. Auto assigned to Ravimal Herath.', 'Delivered', NULL, 0, '2026-08-30 10:22:04', NULL, NULL, NULL),
(325, 15, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for ravimal.herath.fire@helafixit.lk. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 10:25:48', NULL, NULL, NULL),
(326, 477, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for ravimal.herath.fire@helafixit.lk. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 10:25:48', NULL, NULL, NULL),
(327, 478, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for ravimal.herath.fire@helafixit.lk. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 10:25:48', NULL, NULL, NULL),
(328, 479, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for ravimal.herath.fire@helafixit.lk. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 10:25:48', NULL, NULL, NULL),
(329, 480, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for ravimal.herath.fire@helafixit.lk. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 10:25:48', NULL, NULL, NULL),
(330, 481, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for ravimal.herath.fire@helafixit.lk. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 10:25:48', NULL, NULL, NULL),
(331, 482, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for ravimal.herath.fire@helafixit.lk. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 10:25:48', NULL, NULL, NULL),
(332, 483, NULL, 'Password Reset Request', 'In App', 'Password reset request', 'Password reset requested for ravimal.herath.fire@helafixit.lk. Verify the account and issue a temporary password from User Management.', 'Delivered', NULL, 0, '2026-08-30 10:25:48', NULL, NULL, NULL),
(333, 498, 201, 'Ticket Created', 'In App', 'Maintenance ticket received', 'TCK-260830-8A3C97B0 was saved successfully and local AI analysis has started.', 'Delivered', NULL, 0, '2026-08-30 16:34:15', NULL, NULL, NULL),
(334, 402, 201, 'Emergency Assignment', 'In App', 'Emergency maintenance job', 'TCK-260830-8A3C97B0 was automatically assigned to you as an emergency job.', 'Delivered', NULL, 0, '2026-08-30 16:34:18', NULL, NULL, NULL),
(335, 498, 201, 'AI Analysis', 'In App', 'Ticket analysis completed', 'TCK-260830-8A3C97B0 was analysed as Electrical with Emergency priority and risk 100.0/100.', 'Delivered', NULL, 0, '2026-08-30 16:34:18', NULL, NULL, NULL),
(336, 337, 201, 'Emergency AI Analysis', 'In App', 'Emergency ticket requires attention', 'TCK-260830-8A3C97B0 analysed as Electrical / Emergency / risk 100.0. Auto assigned to Sampath Perera.', 'Delivered', NULL, 0, '2026-08-30 16:34:18', NULL, NULL, NULL),
(337, 343, 201, 'Emergency AI Analysis', 'In App', 'Emergency ticket requires attention', 'TCK-260830-8A3C97B0 analysed as Electrical / Emergency / risk 100.0. Auto assigned to Sampath Perera.', 'Delivered', NULL, 0, '2026-08-30 16:34:18', NULL, NULL, NULL),
(338, 498, 201, 'Status Changed', 'In App', 'Ticket status updated', 'TCK-260830-8A3C97B0 status changed to Accepted.', 'Delivered', NULL, 0, '2026-08-30 16:35:23', NULL, NULL, NULL);

-- --------------------------------------------------------

--
-- Table structure for table `notification_preferences`
--

CREATE TABLE `notification_preferences` (
  `notification_preference_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `in_app_enabled` tinyint(1) NOT NULL DEFAULT 1,
  `email_enabled` tinyint(1) NOT NULL DEFAULT 1,
  `sms_enabled` tinyint(1) NOT NULL DEFAULT 0,
  `browser_enabled` tinyint(1) NOT NULL DEFAULT 1,
  `emergency_sms_enabled` tinyint(1) NOT NULL DEFAULT 0,
  `ticket_status_updates_enabled` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `notification_preferences`
--

INSERT INTO `notification_preferences` (`notification_preference_id`, `user_id`, `in_app_enabled`, `email_enabled`, `sms_enabled`, `browser_enabled`, `emergency_sms_enabled`, `ticket_status_updates_enabled`, `created_at`, `updated_at`) VALUES
(186, 335, 1, 1, 1, 1, 1, 1, '2026-08-18 09:00:00', '2026-08-18 09:00:00'),
(187, 336, 1, 1, 1, 1, 1, 1, '2026-08-18 09:48:00', '2026-08-18 09:48:00'),
(188, 337, 1, 1, 1, 1, 1, 1, '2026-08-18 10:12:00', '2026-08-18 10:12:00'),
(189, 338, 1, 1, 1, 1, 1, 1, '2026-08-18 10:36:00', '2026-08-18 10:36:00'),
(190, 339, 1, 1, 1, 1, 1, 1, '2026-08-18 09:24:00', '2026-08-18 09:24:00'),
(191, 340, 1, 1, 1, 1, 1, 1, '2026-08-18 10:00:00', '2026-08-18 10:00:00'),
(192, 341, 1, 1, 1, 1, 1, 1, '2026-08-18 09:12:00', '2026-08-18 09:12:00'),
(193, 342, 1, 1, 1, 1, 1, 1, '2026-08-18 10:48:00', '2026-08-18 10:48:00'),
(194, 343, 1, 1, 1, 1, 1, 1, '2026-08-18 10:24:00', '2026-08-18 10:24:00'),
(195, 344, 1, 1, 1, 1, 1, 1, '2026-08-18 09:36:00', '2026-08-18 09:36:00'),
(196, 272, 1, 1, 0, 1, 0, 1, '2026-08-17 13:30:00', '2026-08-17 13:30:00'),
(197, 273, 1, 1, 0, 1, 0, 1, '2026-08-17 14:33:00', '2026-08-17 14:33:00'),
(198, 274, 1, 1, 0, 1, 0, 1, '2026-08-17 14:00:00', '2026-08-17 14:00:00'),
(199, 275, 1, 1, 0, 1, 0, 1, '2026-08-17 13:45:00', '2026-08-17 13:45:00'),
(200, 276, 1, 1, 0, 1, 0, 1, '2026-08-17 14:18:00', '2026-08-17 14:18:00'),
(201, 277, 1, 1, 0, 1, 0, 1, '2026-08-17 13:06:00', '2026-08-17 13:06:00'),
(202, 278, 1, 1, 0, 1, 0, 1, '2026-08-17 13:42:00', '2026-08-17 13:42:00'),
(203, 279, 1, 1, 0, 1, 0, 1, '2026-08-17 14:15:00', '2026-08-17 14:15:00'),
(204, 280, 1, 1, 0, 1, 0, 1, '2026-08-17 13:09:00', '2026-08-17 13:09:00'),
(205, 281, 1, 1, 0, 1, 0, 1, '2026-08-17 13:54:00', '2026-08-17 13:54:00'),
(206, 282, 1, 1, 0, 1, 0, 1, '2026-08-17 13:39:00', '2026-08-17 13:39:00'),
(207, 283, 1, 1, 0, 1, 0, 1, '2026-08-17 14:09:00', '2026-08-17 14:09:00'),
(208, 284, 1, 1, 0, 1, 0, 1, '2026-08-17 14:24:00', '2026-08-17 14:24:00'),
(209, 285, 1, 1, 0, 1, 0, 1, '2026-08-17 13:03:00', '2026-08-17 13:03:00'),
(210, 286, 1, 1, 0, 1, 0, 1, '2026-08-17 13:51:00', '2026-08-17 13:51:00'),
(211, 287, 1, 1, 0, 1, 0, 1, '2026-08-17 14:36:00', '2026-08-17 14:36:00'),
(212, 288, 1, 1, 0, 1, 0, 1, '2026-08-17 13:18:00', '2026-08-17 13:18:00'),
(213, 289, 1, 1, 0, 1, 0, 1, '2026-08-17 14:48:00', '2026-08-17 14:48:00'),
(214, 290, 1, 1, 0, 1, 0, 1, '2026-08-17 14:27:00', '2026-08-17 14:27:00'),
(215, 291, 1, 1, 0, 1, 0, 1, '2026-08-17 13:12:00', '2026-08-17 13:12:00'),
(216, 292, 1, 1, 0, 1, 0, 1, '2026-08-17 13:15:00', '2026-08-17 13:15:00'),
(217, 293, 1, 1, 0, 1, 0, 1, '2026-08-17 14:45:00', '2026-08-17 14:45:00'),
(218, 294, 1, 1, 0, 1, 0, 1, '2026-08-17 13:36:00', '2026-08-17 13:36:00'),
(219, 295, 1, 1, 0, 1, 0, 1, '2026-08-17 13:21:00', '2026-08-17 13:21:00'),
(220, 296, 1, 1, 0, 1, 0, 1, '2026-08-17 13:57:00', '2026-08-17 13:57:00'),
(221, 297, 1, 1, 0, 1, 0, 1, '2026-08-17 13:00:00', '2026-08-17 13:00:00'),
(222, 298, 1, 1, 0, 1, 0, 1, '2026-08-17 14:42:00', '2026-08-17 14:42:00'),
(223, 299, 1, 1, 0, 1, 0, 1, '2026-08-17 13:33:00', '2026-08-17 13:33:00'),
(224, 300, 1, 1, 0, 1, 0, 1, '2026-08-17 14:06:00', '2026-08-17 14:06:00'),
(225, 301, 1, 1, 0, 1, 0, 1, '2026-08-17 14:21:00', '2026-08-17 14:21:00'),
(226, 302, 1, 1, 0, 1, 0, 1, '2026-08-17 14:39:00', '2026-08-17 14:39:00'),
(227, 303, 1, 1, 0, 1, 0, 1, '2026-08-17 13:24:00', '2026-08-17 13:24:00'),
(228, 304, 1, 1, 0, 1, 0, 1, '2026-08-17 14:12:00', '2026-08-17 14:12:00'),
(229, 305, 1, 1, 0, 1, 0, 1, '2026-08-17 14:03:00', '2026-08-17 14:03:00'),
(230, 306, 1, 1, 0, 1, 0, 1, '2026-08-17 13:27:00', '2026-08-17 13:27:00'),
(231, 307, 1, 1, 0, 1, 0, 1, '2026-08-17 14:51:00', '2026-08-17 14:51:00'),
(232, 308, 1, 1, 0, 1, 0, 1, '2026-08-17 13:48:00', '2026-08-17 13:48:00'),
(233, 309, 1, 1, 0, 1, 0, 1, '2026-08-17 14:30:00', '2026-08-17 14:30:00'),
(234, 15, 1, 1, 0, 1, 0, 1, '2026-08-17 11:48:08', '2026-08-17 11:48:08'),
(235, 477, 1, 1, 0, 1, 0, 1, '2026-08-22 10:15:00', '2026-08-22 10:15:00'),
(236, 478, 1, 1, 0, 1, 0, 1, '2026-08-22 10:00:00', '2026-08-22 10:00:00'),
(237, 479, 1, 1, 0, 1, 0, 1, '2026-08-22 09:15:00', '2026-08-22 09:15:00'),
(238, 480, 1, 1, 0, 1, 0, 1, '2026-08-22 09:30:00', '2026-08-22 09:30:00'),
(239, 481, 1, 1, 0, 1, 0, 1, '2026-08-22 10:30:00', '2026-08-22 10:30:00'),
(240, 482, 1, 1, 0, 1, 0, 1, '2026-08-22 09:00:00', '2026-08-22 09:00:00'),
(241, 483, 1, 1, 0, 1, 0, 1, '2026-08-22 09:45:00', '2026-08-22 09:45:00'),
(242, 350, 1, 1, 1, 1, 1, 1, '2026-08-20 08:30:00', '2026-08-20 08:30:00'),
(243, 351, 1, 1, 1, 1, 1, 1, '2026-08-19 09:50:00', '2026-08-19 09:50:00'),
(244, 352, 1, 1, 1, 1, 1, 1, '2026-08-20 14:00:00', '2026-08-20 14:00:00'),
(245, 353, 1, 1, 1, 1, 1, 1, '2026-08-20 14:10:00', '2026-08-20 14:10:00'),
(246, 354, 1, 1, 1, 1, 1, 1, '2026-08-20 08:40:00', '2026-08-20 08:40:00'),
(247, 355, 1, 1, 1, 1, 1, 1, '2026-08-19 08:40:00', '2026-08-19 08:40:00'),
(248, 356, 1, 1, 1, 1, 1, 1, '2026-08-20 08:50:00', '2026-08-20 08:50:00'),
(249, 357, 1, 1, 1, 1, 1, 1, '2026-08-20 14:20:00', '2026-08-20 14:20:00'),
(250, 358, 1, 1, 1, 1, 1, 1, '2026-08-19 13:30:00', '2026-08-19 13:30:00'),
(251, 359, 1, 1, 1, 1, 1, 1, '2026-08-19 14:40:00', '2026-08-19 14:40:00'),
(252, 360, 1, 1, 1, 1, 1, 1, '2026-08-20 14:30:00', '2026-08-20 14:30:00'),
(253, 361, 1, 1, 1, 1, 1, 1, '2026-08-19 09:00:00', '2026-08-19 09:00:00'),
(254, 362, 1, 1, 1, 1, 1, 1, '2026-08-19 14:50:00', '2026-08-19 14:50:00'),
(255, 363, 1, 1, 1, 1, 1, 1, '2026-08-20 14:40:00', '2026-08-20 14:40:00'),
(256, 364, 1, 1, 1, 1, 1, 1, '2026-08-20 14:50:00', '2026-08-20 14:50:00'),
(257, 365, 1, 1, 1, 1, 1, 1, '2026-08-19 13:00:00', '2026-08-19 13:00:00'),
(258, 366, 1, 1, 1, 1, 1, 1, '2026-08-20 15:00:00', '2026-08-20 15:00:00'),
(259, 367, 1, 1, 1, 1, 1, 1, '2026-08-20 09:00:00', '2026-08-20 09:00:00'),
(260, 368, 1, 1, 1, 1, 1, 1, '2026-08-21 08:30:00', '2026-08-21 08:30:00'),
(261, 369, 1, 1, 1, 1, 1, 1, '2026-08-20 09:10:00', '2026-08-20 09:10:00'),
(262, 370, 1, 1, 1, 1, 1, 1, '2026-08-21 08:40:00', '2026-08-21 08:40:00'),
(263, 371, 1, 1, 1, 1, 1, 1, '2026-08-19 09:10:00', '2026-08-19 09:10:00'),
(264, 372, 1, 1, 1, 1, 1, 1, '2026-08-19 14:10:00', '2026-08-19 14:10:00'),
(265, 373, 1, 1, 1, 1, 1, 1, '2026-08-21 08:50:00', '2026-08-21 08:50:00'),
(266, 374, 1, 1, 1, 1, 1, 1, '2026-08-20 09:20:00', '2026-08-20 09:20:00'),
(267, 375, 1, 1, 1, 1, 1, 1, '2026-08-19 15:00:00', '2026-08-19 15:00:00'),
(268, 376, 1, 1, 1, 1, 1, 1, '2026-08-19 10:30:00', '2026-08-19 10:30:00'),
(269, 377, 1, 1, 1, 1, 1, 1, '2026-08-21 09:00:00', '2026-08-21 09:00:00'),
(270, 378, 1, 1, 1, 1, 1, 1, '2026-08-20 09:30:00', '2026-08-20 09:30:00'),
(271, 379, 1, 1, 1, 1, 1, 1, '2026-08-19 09:30:00', '2026-08-19 09:30:00'),
(272, 380, 1, 1, 1, 1, 1, 1, '2026-08-20 09:40:00', '2026-08-20 09:40:00'),
(273, 381, 1, 1, 1, 1, 1, 1, '2026-08-21 09:10:00', '2026-08-21 09:10:00'),
(274, 382, 1, 1, 1, 1, 1, 1, '2026-08-19 14:00:00', '2026-08-19 14:00:00'),
(275, 383, 1, 1, 1, 1, 1, 1, '2026-08-19 10:10:00', '2026-08-19 10:10:00'),
(276, 384, 1, 1, 1, 1, 1, 1, '2026-08-21 09:20:00', '2026-08-21 09:20:00'),
(277, 385, 1, 1, 1, 1, 1, 1, '2026-08-19 14:30:00', '2026-08-19 14:30:00'),
(278, 386, 1, 1, 1, 1, 1, 1, '2026-08-20 09:50:00', '2026-08-20 09:50:00'),
(279, 387, 1, 1, 1, 1, 1, 1, '2026-08-20 10:00:00', '2026-08-20 10:00:00'),
(280, 388, 1, 1, 1, 1, 1, 1, '2026-08-21 09:30:00', '2026-08-21 09:30:00'),
(281, 389, 1, 1, 1, 1, 1, 1, '2026-08-21 09:40:00', '2026-08-21 09:40:00'),
(282, 390, 1, 1, 1, 1, 1, 1, '2026-08-20 10:10:00', '2026-08-20 10:10:00'),
(283, 391, 1, 1, 1, 1, 1, 1, '2026-08-20 10:20:00', '2026-08-20 10:20:00'),
(284, 392, 1, 1, 1, 1, 1, 1, '2026-08-19 10:00:00', '2026-08-19 10:00:00'),
(285, 393, 1, 1, 1, 1, 1, 1, '2026-08-21 09:50:00', '2026-08-21 09:50:00'),
(286, 394, 1, 1, 1, 1, 1, 1, '2026-08-20 10:30:00', '2026-08-20 10:30:00'),
(287, 395, 1, 1, 1, 1, 1, 1, '2026-08-21 10:00:00', '2026-08-21 10:00:00'),
(288, 396, 1, 1, 1, 1, 1, 1, '2026-08-19 13:20:00', '2026-08-19 13:20:00'),
(289, 397, 1, 1, 1, 1, 1, 1, '2026-08-19 09:40:00', '2026-08-19 09:40:00'),
(290, 398, 1, 1, 1, 1, 1, 1, '2026-08-19 10:20:00', '2026-08-19 10:20:00'),
(291, 399, 1, 1, 1, 1, 1, 1, '2026-08-19 13:10:00', '2026-08-19 13:10:00'),
(292, 400, 1, 1, 1, 1, 1, 1, '2026-08-21 10:10:00', '2026-08-21 10:10:00'),
(293, 401, 1, 1, 1, 1, 1, 1, '2026-08-19 13:50:00', '2026-08-19 13:50:00'),
(294, 402, 1, 1, 1, 1, 1, 1, '2026-08-20 13:00:00', '2026-08-20 13:00:00'),
(295, 403, 1, 1, 1, 1, 1, 1, '2026-08-19 14:20:00', '2026-08-19 14:20:00'),
(296, 404, 1, 1, 1, 1, 1, 1, '2026-08-19 08:50:00', '2026-08-19 08:50:00'),
(297, 405, 1, 1, 1, 1, 1, 1, '2026-08-19 08:30:00', '2026-08-19 08:30:00'),
(298, 406, 1, 1, 1, 1, 1, 1, '2026-08-21 10:20:00', '2026-08-21 10:20:00'),
(299, 407, 1, 1, 1, 1, 1, 1, '2026-08-19 09:20:00', '2026-08-19 09:20:00'),
(300, 408, 1, 1, 1, 1, 1, 1, '2026-08-20 13:10:00', '2026-08-20 13:10:00'),
(301, 409, 1, 1, 1, 1, 1, 1, '2026-08-19 13:40:00', '2026-08-19 13:40:00'),
(302, 410, 1, 1, 1, 1, 1, 1, '2026-08-21 10:30:00', '2026-08-21 10:30:00'),
(303, 411, 1, 1, 1, 1, 1, 1, '2026-08-20 13:20:00', '2026-08-20 13:20:00'),
(304, 412, 1, 1, 1, 1, 1, 1, '2026-08-20 13:30:00', '2026-08-20 13:30:00'),
(305, 413, 1, 1, 1, 1, 1, 1, '2026-08-20 13:40:00', '2026-08-20 13:40:00'),
(306, 414, 1, 1, 1, 1, 1, 1, '2026-08-20 13:50:00', '2026-08-20 13:50:00'),
(307, 484, 1, 1, 0, 1, 0, 1, '2026-08-21 09:00:00', '2026-08-21 09:00:00'),
(308, 485, 1, 1, 0, 1, 0, 1, '2026-08-21 09:37:00', '2026-08-21 09:37:00'),
(309, 486, 1, 1, 1, 1, 0, 1, '2026-08-21 10:14:00', '2026-08-21 10:14:00'),
(310, 487, 1, 1, 0, 1, 0, 1, '2026-08-21 10:51:00', '2026-08-21 10:51:00'),
(311, 488, 1, 1, 0, 1, 0, 1, '2026-08-21 11:28:00', '2026-08-21 11:28:00'),
(312, 489, 1, 1, 1, 1, 0, 1, '2026-08-21 12:05:00', '2026-08-21 12:05:00'),
(313, 490, 1, 1, 0, 1, 0, 1, '2026-08-21 12:42:00', '2026-08-21 12:42:00'),
(314, 491, 1, 1, 0, 1, 0, 1, '2026-08-21 13:19:00', '2026-08-21 13:19:00'),
(315, 492, 1, 1, 1, 1, 0, 1, '2026-08-21 13:56:00', '2026-08-21 13:56:00'),
(316, 493, 1, 1, 0, 1, 0, 1, '2026-08-21 14:33:00', '2026-08-21 14:33:00'),
(317, 494, 1, 1, 0, 1, 0, 1, '2026-08-21 15:10:00', '2026-08-21 15:10:00'),
(318, 495, 1, 1, 1, 1, 0, 1, '2026-08-21 15:47:00', '2026-08-21 15:47:00'),
(319, 496, 1, 1, 0, 1, 0, 1, '2026-08-21 16:24:00', '2026-08-21 16:24:00'),
(320, 497, 1, 1, 0, 1, 0, 1, '2026-08-21 17:01:00', '2026-08-21 17:01:00'),
(321, 498, 1, 1, 1, 1, 0, 1, '2026-08-21 17:38:00', '2026-08-21 17:38:00'),
(322, 499, 1, 1, 0, 1, 0, 1, '2026-08-21 18:15:00', '2026-08-21 18:15:00'),
(323, 500, 1, 1, 0, 1, 0, 1, '2026-08-21 18:52:00', '2026-08-21 18:52:00'),
(324, 501, 1, 1, 1, 1, 0, 1, '2026-08-21 19:29:00', '2026-08-21 19:29:00'),
(325, 502, 1, 1, 0, 1, 0, 1, '2026-08-21 20:06:00', '2026-08-21 20:06:00'),
(326, 503, 1, 1, 0, 1, 0, 1, '2026-08-21 20:43:00', '2026-08-21 20:43:00'),
(327, 504, 1, 1, 1, 1, 0, 1, '2026-08-21 21:20:00', '2026-08-21 21:20:00'),
(328, 505, 1, 1, 0, 1, 0, 1, '2026-08-21 21:57:00', '2026-08-21 21:57:00'),
(329, 506, 1, 1, 0, 1, 0, 1, '2026-08-29 14:04:27', '2026-08-29 14:04:27'),
(330, 507, 1, 1, 0, 1, 0, 1, '2026-08-29 14:10:46', '2026-08-29 14:10:46');

-- --------------------------------------------------------

--
-- Table structure for table `notification_templates`
--

CREATE TABLE `notification_templates` (
  `notification_template_id` bigint(20) UNSIGNED NOT NULL,
  `template_code` varchar(80) NOT NULL,
  `event_type` varchar(80) NOT NULL,
  `channel` enum('In App','Email','SMS','Push','WhatsApp') NOT NULL,
  `subject_template` varchar(255) DEFAULT NULL,
  `message_template` text NOT NULL,
  `active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `notification_templates`
--

INSERT INTO `notification_templates` (`notification_template_id`, `template_code`, `event_type`, `channel`, `subject_template`, `message_template`, `active`, `created_at`, `updated_at`) VALUES
(1, 'ticket_created', 'Ticket Created', 'In App', NULL, 'Your maintenance ticket {{ticket_number}} was created.', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(2, 'ticket_assigned', 'Ticket Assignment', 'In App', NULL, 'Ticket {{ticket_number}} was assigned to {{technician_name}}.', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(3, 'emergency_assignment', 'Emergency Assignment', 'In App', NULL, 'Emergency ticket {{ticket_number}} requires immediate attention.', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(4, 'status_changed', 'Status Changed', 'In App', NULL, 'Ticket {{ticket_number}} status changed to {{status}}.', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(5, 'ticket_completed', 'Ticket Completed', 'In App', NULL, 'Ticket {{ticket_number}} was marked resolved.', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(6, 'duplicate_found', 'Duplicate Detected', 'In App', NULL, 'A possible duplicate was found for {{ticket_number}}.', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19');

-- --------------------------------------------------------

--
-- Table structure for table `password_reset_tokens`
--

CREATE TABLE `password_reset_tokens` (
  `reset_token_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `token_hash` char(64) NOT NULL,
  `expires_at` datetime NOT NULL,
  `used_at` datetime DEFAULT NULL,
  `requested_ip` varchar(45) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `password_reset_tokens`
--

INSERT INTO `password_reset_tokens` (`reset_token_id`, `user_id`, `token_hash`, `expires_at`, `used_at`, `requested_ip`, `created_at`) VALUES
(1, 505, '1749bccdb1d875d9c9f43d45e323cc24d63e840b920061383c6a07e16b010966', '2026-08-31 10:03:48', '2026-08-30 10:05:24', '127.0.0.1', '2026-08-30 10:03:48'),
(2, 395, 'dd1110c91edcc8df9d9f20b9ef3d52ff1069f4ef78b9da1e0b00893c128b86ba', '2026-08-31 10:25:48', NULL, '127.0.0.1', '2026-08-30 10:25:48');

-- --------------------------------------------------------

--
-- Table structure for table `permissions`
--

CREATE TABLE `permissions` (
  `permission_id` bigint(20) UNSIGNED NOT NULL,
  `permission_code` varchar(100) NOT NULL,
  `description` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `permissions`
--

INSERT INTO `permissions` (`permission_id`, `permission_code`, `description`, `created_at`) VALUES
(1, 'ticket.create', 'Create a maintenance ticket', '2026-08-15 13:50:18'),
(2, 'ticket.read.own', 'Read own maintenance tickets', '2026-08-15 13:50:18'),
(3, 'ticket.read.all', 'Read all apartment maintenance tickets', '2026-08-15 13:50:18'),
(4, 'ticket.cancel.own', 'Cancel an eligible own ticket', '2026-08-15 13:50:18'),
(5, 'ticket.reopen.own', 'Reopen an eligible own ticket', '2026-08-15 13:50:18'),
(6, 'ticket.review.ai', 'Review AI prediction and risk output', '2026-08-15 13:50:18'),
(7, 'ticket.override.ai', 'Correct or override AI output with a reason', '2026-08-15 13:50:18'),
(8, 'ticket.assign', 'Assign a technician', '2026-08-15 13:50:18'),
(9, 'ticket.reassign', 'Reassign a technician', '2026-08-15 13:50:18'),
(10, 'ticket.duplicate.review', 'Review duplicate ticket matches', '2026-08-15 13:50:18'),
(11, 'ticket.status.update.assigned', 'Update status for assigned jobs', '2026-08-15 13:50:18'),
(12, 'ticket.note.add.assigned', 'Add repair and progress notes', '2026-08-15 13:50:18'),
(13, 'ticket.complete.assigned', 'Complete an assigned job', '2026-08-15 13:50:18'),
(14, 'ticket.attachment.upload', 'Upload authorised ticket evidence', '2026-08-15 13:50:18'),
(15, 'reports.view', 'View operational reports', '2026-08-15 13:50:18'),
(16, 'reports.export', 'Export authorised report data', '2026-08-15 13:50:18'),
(17, 'technician.manage.operational', 'Manage technician operational availability and workload', '2026-08-15 13:50:18'),
(18, 'user.manage', 'Create and manage user accounts', '2026-08-15 13:50:18'),
(19, 'role.manage', 'Manage system roles', '2026-08-15 13:50:18'),
(20, 'permission.manage', 'Manage role permission mappings', '2026-08-15 13:50:18'),
(21, 'location.manage', 'Manage buildings, floors, units and areas', '2026-08-15 13:50:18'),
(22, 'category.manage', 'Manage issue categories', '2026-08-15 13:50:18'),
(23, 'skill.manage', 'Manage technician skills', '2026-08-15 13:50:18'),
(24, 'safety_rule.manage', 'Manage safety rules', '2026-08-15 13:50:18'),
(25, 'system.settings.update', 'Update system configuration settings', '2026-08-15 13:50:18'),
(26, 'backup.manage', 'Create and review backups', '2026-08-15 13:50:18'),
(27, 'audit.view', 'View audit records', '2026-08-15 13:50:18'),
(28, 'model.manage', 'Manage AI model version records', '2026-08-15 13:50:18'),
(29, 'notification.manage', 'Manage notification configuration', '2026-08-15 13:50:18'),
(30, 'registration.review', 'Review resident registration requests', '2026-08-17 11:54:53');

-- --------------------------------------------------------

--
-- Table structure for table `resident_profiles`
--

CREATE TABLE `resident_profiles` (
  `resident_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `building_id` bigint(20) UNSIGNED NOT NULL,
  `floor_id` bigint(20) UNSIGNED NOT NULL,
  `unit_id` bigint(20) UNSIGNED DEFAULT NULL,
  `unit_number` varchar(40) DEFAULT NULL,
  `resident_type` enum('Owner','Tenant','Family','Other') NOT NULL DEFAULT 'Other',
  `preferred_language` enum('English','Sinhala','Singlish','Mixed') NOT NULL DEFAULT 'English',
  `contact_preference` enum('In App','Email','SMS','Phone') NOT NULL DEFAULT 'In App',
  `profile_status` enum('Active','Inactive') NOT NULL DEFAULT 'Active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `resident_profiles`
--

INSERT INTO `resident_profiles` (`resident_id`, `user_id`, `building_id`, `floor_id`, `unit_id`, `unit_number`, `resident_type`, `preferred_language`, `contact_preference`, `profile_status`, `created_at`, `updated_at`) VALUES
(87, 272, 2, 4, 4, 'B-303', 'Family', 'Singlish', 'SMS', 'Active', '2026-08-17 13:30:00', '2026-08-17 13:30:00'),
(88, 273, 7, 62, 5, 'E-101', 'Owner', 'Mixed', 'In App', 'Active', '2026-08-17 14:33:00', '2026-08-17 14:33:00'),
(89, 274, 3, 20, 6, 'C-505', 'Owner', 'English', 'In App', 'Active', '2026-08-17 14:00:00', '2026-08-17 14:00:00'),
(90, 275, 2, 28, 7, 'B-808', 'Owner', 'Mixed', 'In App', 'Active', '2026-08-17 13:45:00', '2026-08-17 13:45:00'),
(91, 276, 4, 54, 8, 'D-303', 'Family', 'Singlish', 'SMS', 'Active', '2026-08-17 14:18:00', '2026-08-17 14:18:00'),
(92, 277, 1, 14, 9, 'A-303', 'Family', 'Singlish', 'SMS', 'Active', '2026-08-17 13:06:00', '2026-08-17 13:06:00'),
(93, 278, 2, 25, 10, 'B-707', 'Tenant', 'Singlish', 'SMS', 'Active', '2026-08-17 13:42:00', '2026-08-17 13:42:00'),
(94, 279, 4, 53, 11, 'D-202', 'Tenant', 'Sinhala', 'Email', 'Active', '2026-08-17 14:15:00', '2026-08-17 14:15:00'),
(95, 280, 1, 16, 12, 'A-404', 'Tenant', 'Mixed', 'In App', 'Active', '2026-08-17 13:09:00', '2026-08-17 13:09:00'),
(96, 281, 3, 15, 13, 'C-303', 'Family', 'Singlish', 'SMS', 'Active', '2026-08-17 13:54:00', '2026-08-17 13:54:00'),
(97, 282, 2, 22, 14, 'B-606', 'Family', 'Sinhala', 'Email', 'Active', '2026-08-17 13:39:00', '2026-08-17 13:39:00'),
(98, 283, 3, 7, 15, 'C-808', 'Owner', 'Mixed', 'In App', 'Active', '2026-08-17 14:09:00', '2026-08-17 14:09:00'),
(99, 284, 4, 56, 16, 'D-505', 'Owner', 'English', 'In App', 'Active', '2026-08-17 14:24:00', '2026-08-17 14:24:00'),
(100, 285, 1, 11, 17, 'A-202', 'Tenant', 'Sinhala', 'Email', 'Active', '2026-08-17 13:03:00', '2026-08-17 13:03:00'),
(101, 286, 3, 13, 18, 'C-202', 'Tenant', 'Sinhala', 'Email', 'Active', '2026-08-17 13:51:00', '2026-08-17 13:51:00'),
(102, 287, 7, 63, 19, 'E-202', 'Tenant', 'English', 'In App', 'Active', '2026-08-17 14:36:00', '2026-08-17 14:36:00'),
(103, 288, 1, 24, 20, 'A-707', 'Tenant', 'Singlish', 'SMS', 'Active', '2026-08-17 13:18:00', '2026-08-17 13:18:00'),
(104, 289, 7, 67, 21, 'E-606', 'Family', 'English', 'In App', 'Active', '2026-08-17 14:48:00', '2026-08-17 14:48:00'),
(105, 290, 4, 57, 22, 'D-606', 'Family', 'Sinhala', 'Email', 'Active', '2026-08-17 14:27:00', '2026-08-17 14:27:00'),
(106, 291, 1, 2, 23, 'A-505', 'Owner', 'English', 'In App', 'Active', '2026-08-17 13:12:00', '2026-08-17 13:12:00'),
(107, 292, 1, 21, 24, 'A-606', 'Family', 'Sinhala', 'Email', 'Active', '2026-08-17 13:15:00', '2026-08-17 13:15:00'),
(108, 293, 7, 66, 25, 'E-505', 'Owner', 'Mixed', 'In App', 'Active', '2026-08-17 14:45:00', '2026-08-17 14:45:00'),
(109, 294, 2, 19, 26, 'B-505', 'Owner', 'English', 'In App', 'Active', '2026-08-17 13:36:00', '2026-08-17 13:36:00'),
(110, 295, 1, 27, 27, 'A-808', 'Owner', 'Mixed', 'In App', 'Active', '2026-08-17 13:21:00', '2026-08-17 13:21:00'),
(111, 296, 3, 18, 28, 'C-404', 'Tenant', 'Mixed', 'In App', 'Active', '2026-08-17 13:57:00', '2026-08-17 13:57:00'),
(112, 297, 1, 8, 29, 'A-101', 'Owner', 'English', 'In App', 'Active', '2026-08-17 13:00:00', '2026-08-17 13:00:00'),
(113, 298, 7, 65, 30, 'E-404', 'Tenant', 'Singlish', 'SMS', 'Active', '2026-08-17 14:42:00', '2026-08-17 14:42:00'),
(114, 299, 2, 17, 31, 'B-404', 'Tenant', 'Mixed', 'In App', 'Active', '2026-08-17 13:33:00', '2026-08-17 13:33:00'),
(115, 300, 3, 26, 32, 'C-707', 'Tenant', 'Singlish', 'SMS', 'Active', '2026-08-17 14:06:00', '2026-08-17 14:06:00'),
(116, 301, 4, 55, 33, 'D-404', 'Tenant', 'Mixed', 'In App', 'Active', '2026-08-17 14:21:00', '2026-08-17 14:21:00'),
(117, 302, 7, 64, 34, 'E-303', 'Family', 'Sinhala', 'Email', 'Active', '2026-08-17 14:39:00', '2026-08-17 14:39:00'),
(118, 303, 2, 9, 35, 'B-101', 'Owner', 'English', 'In App', 'Active', '2026-08-17 13:24:00', '2026-08-17 13:24:00'),
(119, 304, 4, 52, 36, 'D-101', 'Owner', 'English', 'In App', 'Active', '2026-08-17 14:12:00', '2026-08-17 14:12:00'),
(120, 305, 3, 23, 37, 'C-606', 'Family', 'Sinhala', 'Email', 'Active', '2026-08-17 14:03:00', '2026-08-17 14:03:00'),
(121, 306, 2, 12, 38, 'B-202', 'Tenant', 'Sinhala', 'Email', 'Active', '2026-08-17 13:27:00', '2026-08-17 13:27:00'),
(122, 307, 7, 68, 39, 'E-707', 'Tenant', 'Sinhala', 'Email', 'Active', '2026-08-17 14:51:00', '2026-08-17 14:51:00'),
(123, 308, 3, 10, 40, 'C-101', 'Owner', 'English', 'In App', 'Active', '2026-08-17 13:48:00', '2026-08-17 13:48:00'),
(124, 309, 4, 58, 41, 'D-707', 'Tenant', 'Singlish', 'SMS', 'Active', '2026-08-17 14:30:00', '2026-08-17 14:30:00'),
(125, 484, 1, 29, 68, 'A-903', 'Owner', 'English', 'Email', 'Active', '2026-08-21 09:00:00', '2026-08-21 09:00:00'),
(126, 485, 1, 32, 69, 'A-1004', 'Tenant', 'Sinhala', 'In App', 'Active', '2026-08-21 09:37:00', '2026-08-21 09:37:00'),
(127, 486, 1, 38, 70, 'A-1202', 'Family', 'Mixed', 'SMS', 'Active', '2026-08-21 10:14:00', '2026-08-21 10:14:00'),
(128, 487, 1, 44, 71, 'A-1405', 'Owner', 'Singlish', 'Email', 'Active', '2026-08-21 10:51:00', '2026-08-21 10:51:00'),
(129, 488, 1, 47, 72, 'A-1506', 'Tenant', 'English', 'In App', 'Active', '2026-08-21 11:28:00', '2026-08-21 11:28:00'),
(130, 489, 2, 30, 73, 'B-902', 'Family', 'Sinhala', 'SMS', 'Active', '2026-08-21 12:05:00', '2026-08-21 12:05:00'),
(131, 490, 2, 33, 74, 'B-1003', 'Owner', 'English', 'Email', 'Active', '2026-08-21 12:42:00', '2026-08-21 12:42:00'),
(132, 491, 2, 39, 75, 'B-1204', 'Tenant', 'Mixed', 'In App', 'Active', '2026-08-21 13:19:00', '2026-08-21 13:19:00'),
(133, 492, 2, 45, 76, 'B-1402', 'Family', 'Singlish', 'SMS', 'Active', '2026-08-21 13:56:00', '2026-08-21 13:56:00'),
(134, 493, 3, 31, 77, 'C-903', 'Owner', 'English', 'Email', 'Active', '2026-08-21 14:33:00', '2026-08-21 14:33:00'),
(135, 494, 3, 34, 78, 'C-1002', 'Tenant', 'Sinhala', 'In App', 'Active', '2026-08-21 15:10:00', '2026-08-21 15:10:00'),
(136, 495, 3, 40, 79, 'C-1203', 'Family', 'Mixed', 'SMS', 'Active', '2026-08-21 15:47:00', '2026-08-21 15:47:00'),
(137, 496, 3, 46, 80, 'C-1404', 'Owner', 'English', 'Email', 'Active', '2026-08-21 16:24:00', '2026-08-21 16:24:00'),
(138, 497, 3, 51, 81, 'C-1602', 'Tenant', 'Singlish', 'In App', 'Active', '2026-08-21 17:01:00', '2026-08-21 17:01:00'),
(139, 498, 4, 59, 82, 'D-802', 'Family', 'Sinhala', 'SMS', 'Active', '2026-08-21 17:38:00', '2026-08-21 17:38:00'),
(140, 499, 4, 60, 83, 'D-903', 'Owner', 'English', 'Email', 'Active', '2026-08-21 18:15:00', '2026-08-21 18:15:00'),
(141, 500, 4, 61, 84, 'D-1004', 'Tenant', 'Mixed', 'In App', 'Active', '2026-08-21 18:52:00', '2026-08-21 18:52:00'),
(142, 501, 4, 57, 85, 'D-602', 'Family', 'Singlish', 'SMS', 'Active', '2026-08-21 19:29:00', '2026-08-21 19:29:00'),
(143, 502, 7, 69, 86, 'E-802', 'Owner', 'English', 'Email', 'Active', '2026-08-21 20:06:00', '2026-08-21 20:06:00'),
(144, 503, 7, 70, 87, 'E-903', 'Tenant', 'Sinhala', 'In App', 'Active', '2026-08-21 20:43:00', '2026-08-21 20:43:00'),
(145, 504, 7, 71, 88, 'E-1004', 'Family', 'Mixed', 'Email', 'Active', '2026-08-21 21:20:00', '2026-08-29 12:26:00'),
(146, 505, 7, 72, 89, 'E-1102', 'Owner', 'Singlish', 'Email', 'Active', '2026-08-21 21:57:00', '2026-08-21 21:57:00'),
(147, 506, 1, 2, NULL, 'A-504', 'Owner', 'English', 'In App', 'Active', '2026-08-29 14:04:27', '2026-08-29 14:04:27'),
(148, 507, 1, 50, NULL, 'B-001', 'Other', 'Sinhala', 'In App', 'Active', '2026-08-29 14:10:46', '2026-08-29 14:10:46');

-- --------------------------------------------------------

--
-- Table structure for table `resident_registration_requests`
--

CREATE TABLE `resident_registration_requests` (
  `request_id` bigint(20) UNSIGNED NOT NULL,
  `full_name` varchar(150) NOT NULL,
  `email` varchar(190) NOT NULL,
  `phone` varchar(30) NOT NULL,
  `complex_id` bigint(20) UNSIGNED NOT NULL,
  `building_id` bigint(20) UNSIGNED NOT NULL,
  `floor_id` bigint(20) UNSIGNED NOT NULL,
  `unit_id` bigint(20) UNSIGNED DEFAULT NULL,
  `unit_number` varchar(40) DEFAULT NULL,
  `resident_type` enum('Owner','Tenant','Family','Other') NOT NULL DEFAULT 'Other',
  `preferred_language` enum('English','Sinhala','Singlish','Mixed') NOT NULL DEFAULT 'English',
  `contact_preference` enum('In App','Email','SMS','Phone') NOT NULL DEFAULT 'In App',
  `password_hash` varchar(255) NOT NULL,
  `request_status` enum('Pending','Approved','Rejected','Cancelled') NOT NULL DEFAULT 'Pending',
  `requested_at` datetime NOT NULL DEFAULT current_timestamp(),
  `reviewed_by` bigint(20) UNSIGNED DEFAULT NULL,
  `reviewed_at` datetime DEFAULT NULL,
  `review_note` varchar(1000) DEFAULT NULL,
  `created_user_id` bigint(20) UNSIGNED DEFAULT NULL,
  `source_ip` varchar(45) DEFAULT NULL,
  `user_agent` varchar(500) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `resident_registration_requests`
--

INSERT INTO `resident_registration_requests` (`request_id`, `full_name`, `email`, `phone`, `complex_id`, `building_id`, `floor_id`, `unit_id`, `unit_number`, `resident_type`, `preferred_language`, `contact_preference`, `password_hash`, `request_status`, `requested_at`, `reviewed_by`, `reviewed_at`, `review_note`, `created_user_id`, `source_ip`, `user_agent`) VALUES
(1, 'Ayesha Wickramanayake', 'ayesha.wickramanayake@outlook.com', '+94780309415', 1, 3, 7, NULL, 'C-807', 'Owner', 'English', 'In App', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-24 15:03:00', NULL, NULL, NULL, NULL, '192.168.30.24', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(2, 'Chathurika Ranasinghe', 'chathurika.ranasinghe@gmail.com', '+94713100941', 1, 2, 22, NULL, 'B-607', 'Family', 'Sinhala', 'Phone', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-26 13:14:00', NULL, NULL, NULL, NULL, '192.168.20.49', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(3, 'Dasun Rathnayake', 'dasun.rathnayake@outlook.com', '+94786707442', 1, 4, 54, NULL, 'D-304', 'Tenant', 'English', 'In App', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-26 10:12:00', NULL, NULL, NULL, NULL, '192.168.40.33', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(4, 'Dinesh Karunaratne', 'dinesh.karunaratne@gmail.com', '+94771952088', 1, 3, 34, NULL, 'C-1003', 'Tenant', 'Singlish', 'SMS', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-25 17:21:00', NULL, NULL, NULL, NULL, '192.168.30.42', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(5, 'Hirushi Senanayake', 'hirushi.senanayake@live.com', '+94780645485', 1, 4, 57, NULL, 'D-603', 'Family', 'Sinhala', 'Email', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-28 14:07:00', NULL, NULL, NULL, NULL, '192.168.40.61', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(6, 'Imalka Herath', 'imalka.herath@gmail.com', '+94752525020', 1, 7, 67, NULL, 'E-607', 'Other', 'English', 'SMS', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Rejected', '2026-08-28 16:31:00', 15, '2026-08-29 14:04:09', 'Registration request rejected.', NULL, '192.168.50.79', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(7, 'Isuru Weerakoon', 'isuru.weerakoon@live.com', '+94726934178', 1, 2, 19, NULL, 'B-506', 'Owner', 'English', 'In App', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-25 08:55:00', NULL, NULL, NULL, NULL, '192.168.20.37', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(8, 'Kaveesha Nadeeshani', 'kaveesha.nadeeshani@hotmail.com', '+94743250906', 1, 3, 49, NULL, 'C-1505', 'Owner', 'Mixed', 'Phone', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-28 11:53:00', NULL, NULL, NULL, NULL, '192.168.30.69', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(9, 'Kavindu Dissanayake', 'kavindu.dissanayake@icloud.com', '+94756397011', 1, 7, 63, NULL, 'E-203', 'Tenant', 'English', 'Email', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-25 12:16:00', NULL, NULL, NULL, NULL, '192.168.50.29', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(10, 'Lakmini Weerasinghe', 'lakmini.weerasinghe@outlook.com', '+94724893138', 1, 7, 65, NULL, 'E-405', 'Owner', 'Mixed', 'Phone', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-27 09:27:00', NULL, NULL, NULL, NULL, '192.168.50.53', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(11, 'Menaka Rodrigo', 'menaka.rodrigo@hotmail.com', '+94768008579', 1, 1, 38, NULL, 'A-1203', 'Family', 'Mixed', 'Phone', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-27 11:47:00', NULL, NULL, NULL, NULL, '192.168.10.58', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(12, 'Nadeesha Gunasekara', 'nadeesha.gunasekara@hotmail.com', '+94707367209', 1, 7, 64, NULL, 'E-304', 'Family', 'Sinhala', 'In App', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-26 15:44:00', NULL, NULL, NULL, NULL, '192.168.50.41', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(13, 'Nethmi Abeysekara', 'nethmi.abeysekara@outlook.com', '+94708449238', 1, 2, 4, NULL, 'B-304', 'Tenant', 'Singlish', 'Email', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-24 10:26:00', NULL, NULL, NULL, NULL, '192.168.20.21', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(14, 'Ruvini Gamage', 'ruvini.gamage@icloud.com', '+94754969928', 1, 3, 40, NULL, 'C-1204', 'Family', 'Sinhala', 'Email', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-27 08:36:00', NULL, NULL, NULL, NULL, '192.168.30.55', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(15, 'Sahan Lakmal', 'sahan.lakmal@icloud.com', '+94787316723', 1, 2, 30, NULL, 'B-903', 'Tenant', 'Mixed', 'SMS', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-27 16:08:00', NULL, NULL, NULL, NULL, '192.168.20.63', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(16, 'Savindi Perera', 'savindi.perera26@gmail.com', '+94770125001', 1, 1, 2, NULL, 'A-504', 'Owner', 'English', 'In App', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Approved', '2026-08-24 09:18:00', 15, '2026-08-29 14:04:27', 'Registration approved.', 506, '192.168.10.31', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(17, 'Shashika Fernando', 'shashika.fernando@gmail.com', '+94709947460', 1, 7, 62, NULL, 'E-102', 'Owner', 'Singlish', 'SMS', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-24 11:39:00', NULL, NULL, NULL, NULL, '192.168.50.18', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(18, 'Tharindu Jayasinghe', 'tharindu.jayasinghe@icloud.com', '+94764149380', 1, 1, 32, NULL, 'A-1005', 'Tenant', 'Sinhala', 'SMS', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-25 14:32:00', NULL, NULL, NULL, NULL, '192.168.10.44', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(19, 'Thisara Bandara', 'thisara.bandara@live.com', '+94716733885', 1, 7, 66, NULL, 'E-506', 'Tenant', 'Singlish', 'In App', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-28 08:19:00', NULL, NULL, NULL, NULL, '192.168.50.67', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(20, 'Vihanga Peiris', 'vihanga.peiris@hotmail.com', '+94748539641', 1, 2, 33, NULL, 'B-1004', 'Other', 'English', 'Email', 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d', 'Pending', '2026-08-28 09:41:00', NULL, NULL, NULL, NULL, '192.168.20.76', 'Mozilla/5.0 HelaFixIt Resident Registration'),
(32, 'Rakindu Fernando', 'nirmalfernando@gmail.com', '+94722009223', 1, 1, 50, NULL, 'B-001', 'Other', 'Sinhala', 'In App', 'pbkdf2:sha256:600000$QatScGxYpLSdlTfF$051e2855334d89af9daa211041861195f06e5049d151093110f6868b1b026eb2', 'Approved', '2026-08-29 14:09:52', 341, '2026-08-29 14:10:46', 'Approved', 507, '127.0.0.1', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36');

-- --------------------------------------------------------

--
-- Table structure for table `revoked_tokens`
--

CREATE TABLE `revoked_tokens` (
  `revoked_token_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `token_jti` varchar(120) NOT NULL,
  `token_type` enum('Access','Refresh') NOT NULL,
  `expires_at` datetime NOT NULL,
  `revoked_at` datetime NOT NULL DEFAULT current_timestamp(),
  `reason` varchar(255) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `revoked_tokens`
--

INSERT INTO `revoked_tokens` (`revoked_token_id`, `user_id`, `token_jti`, `token_type`, `expires_at`, `revoked_at`, `reason`) VALUES
(12, 335, '0913a00d-7934-4bc5-b217-ce7fc2d75ff6', 'Access', '2026-08-24 09:07:19', '2026-08-24 01:19:34', 'User logout'),
(13, 297, '7598cfd6-c32f-48f5-bccb-01c5c16de0a0', 'Access', '2026-08-24 09:19:43', '2026-08-24 01:19:48', 'User logout'),
(14, 335, 'd414e1c8-4fd2-4048-9b4d-c964563063a5', 'Access', '2026-08-25 07:02:52', '2026-08-24 23:03:35', 'User logout'),
(15, 15, 'd2dea1a5-91cd-41f3-aecd-c08b94531648', 'Access', '2026-08-25 09:35:56', '2026-08-25 01:36:13', 'User logout'),
(16, 297, 'cfd9e9f0-ee41-4cc3-b1f4-bfc8e34fe3e0', 'Access', '2026-08-25 09:49:55', '2026-08-25 01:50:20', 'User logout'),
(17, 15, 'c986869d-a58e-4b47-b75c-89bad70bc996', 'Access', '2026-08-26 22:48:17', '2026-08-26 14:48:52', 'User logout'),
(18, 335, '47e4db84-ac4f-45c0-8eb9-0f6467a08a7a', 'Access', '2026-08-26 22:49:04', '2026-08-26 14:49:59', 'User logout'),
(19, 405, 'bd1c1945-4c4f-412f-b61d-031c22d18dcf', 'Access', '2026-08-26 22:50:10', '2026-08-26 14:50:26', 'User logout'),
(20, 15, 'ab097966-97d8-44b8-8319-3e3442690c03', 'Access', '2026-08-27 01:25:32', '2026-08-26 17:27:06', 'User logout'),
(21, 481, 'e9ccf6d3-8c22-4f10-9ce3-4ecaaf2594f2', 'Access', '2026-08-27 01:27:17', '2026-08-26 17:28:10', 'User logout'),
(22, 373, '74c0b6b0-0378-4b2e-b5e3-b2d045df383e', 'Access', '2026-08-27 01:28:20', '2026-08-26 17:28:45', 'User logout'),
(23, 15, '2e22d32b-b8e9-4463-a3e7-74d2d2adc097', 'Access', '2026-08-27 01:28:53', '2026-08-26 17:29:19', 'User logout'),
(24, 342, 'a0281a41-b008-443c-bf27-16f58cb0c71b', 'Access', '2026-08-27 01:29:30', '2026-08-26 17:30:19', 'User logout'),
(25, 15, 'a4d42fdf-cb42-44e6-93fb-8c4506535a8b', 'Access', '2026-08-27 01:30:27', '2026-08-26 18:29:01', 'User logout'),
(26, 344, '4fb5a998-903d-4232-8337-b80813a1afce', 'Access', '2026-08-27 02:29:09', '2026-08-26 18:38:25', 'User logout'),
(27, 15, '06baf751-e874-4610-88da-a37650c1163b', 'Access', '2026-08-27 02:38:34', '2026-08-26 18:38:53', 'User logout'),
(28, 300, '75746501-5802-47fb-9831-113c6ed17289', 'Access', '2026-08-27 02:39:12', '2026-08-26 18:44:59', 'User logout'),
(29, 15, 'ad1dd01c-5356-4677-b950-d577f8a2dc60', 'Access', '2026-08-27 02:45:08', '2026-08-26 18:45:25', 'User logout'),
(30, 340, 'f9782f7e-8dc7-40f0-9caf-81a190cefbf0', 'Access', '2026-08-27 02:45:33', '2026-08-26 18:46:02', 'User logout'),
(31, 15, '5eb9007a-e7a9-4ff0-bab8-300b4915d013', 'Access', '2026-08-27 02:46:21', '2026-08-26 18:46:35', 'User logout'),
(32, 336, '3c677218-8de0-4288-8e16-8c7e75e93999', 'Access', '2026-08-27 02:46:46', '2026-08-26 18:46:51', 'User logout'),
(33, 15, '6a6ddb57-28db-4703-8d43-00e3e32ed170', 'Access', '2026-08-27 02:47:00', '2026-08-26 18:47:17', 'User logout'),
(34, 339, '2c00279f-f1eb-4175-a56f-ca05ab4db508', 'Access', '2026-08-27 02:47:26', '2026-08-26 18:47:35', 'User logout'),
(35, 335, 'e93834d3-1a7e-474c-ad2c-e34ff93652a7', 'Access', '2026-08-27 02:47:45', '2026-08-26 18:47:56', 'User logout'),
(36, 15, '0a2d6ee9-669a-4bd2-a3b7-d4cc4bef41b1', 'Access', '2026-08-27 02:48:08', '2026-08-26 18:54:29', 'User logout'),
(37, 300, '60856bd4-0155-40e7-9c19-9d81d403aa89', 'Access', '2026-08-27 02:54:38', '2026-08-26 18:54:48', 'User logout'),
(38, 15, '51c96773-0031-4b8b-bf9f-7275be4785c8', 'Access', '2026-08-27 02:55:00', '2026-08-26 18:55:23', 'User logout'),
(39, 300, 'd5cee0df-ba7c-40c9-8307-318b9306450d', 'Access', '2026-08-27 02:55:34', '2026-08-26 18:55:52', 'User logout'),
(40, 15, '2df7b7f1-8d0e-4bb0-908e-1eba5c136fb5', 'Access', '2026-08-27 02:56:16', '2026-08-26 18:56:26', 'User logout'),
(41, 336, 'e10889fb-7ba1-4d36-9c0e-fd445f685b86', 'Access', '2026-08-27 02:56:35', '2026-08-26 18:58:03', 'User logout'),
(42, 15, '7df24a74-2e25-46d3-9380-53cad3107a49', 'Access', '2026-08-27 02:58:18', '2026-08-26 18:58:30', 'User logout'),
(43, 15, 'bc0376c8-afe8-405a-9123-1136bb823f81', 'Access', '2026-08-27 02:59:33', '2026-08-26 18:59:46', 'User logout'),
(44, 369, 'c055fe11-ff68-4eb0-af43-22e6cd01c8d0', 'Access', '2026-08-27 02:58:40', '2026-08-26 19:03:02', 'User logout'),
(45, 15, '546d6435-5ea3-4c3b-92a0-63d978d564d6', 'Access', '2026-08-27 04:41:42', '2026-08-26 20:42:31', 'User logout'),
(46, 335, '60b37ab5-5a1b-487f-a7c6-b287a3b7eb87', 'Access', '2026-08-27 04:47:54', '2026-08-26 20:48:53', 'User logout'),
(47, 15, 'e60c5686-b40e-43c3-9f54-5c40f26bfa3a', 'Access', '2026-08-27 04:43:49', '2026-08-26 20:53:46', 'User logout'),
(48, 15, '06f5ea8d-1f10-4fbc-8a30-d1f675aa1c33', 'Access', '2026-08-27 07:53:25', '2026-08-26 23:56:12', 'User logout'),
(49, 15, '4bab3156-4204-430c-9ff7-ce4974194e8f', 'Access', '2026-08-27 07:57:03', '2026-08-27 00:35:05', 'User logout'),
(50, 15, 'b54f00c6-2872-4d02-b0c7-e8a48c39c35e', 'Access', '2026-08-27 09:18:15', '2026-08-27 01:18:27', 'User logout'),
(51, 335, '460d4028-9a5b-4f29-b614-5b3e8b4227a3', 'Access', '2026-08-27 09:18:54', '2026-08-27 01:19:21', 'User logout'),
(52, 297, '163765bf-7510-4575-ab96-66e21749a60d', 'Access', '2026-08-27 09:21:10', '2026-08-27 01:21:21', 'User logout'),
(53, 335, 'a054001c-c400-4ae6-bd0b-2e00158079c9', 'Access', '2026-08-27 09:21:34', '2026-08-27 01:21:58', 'User logout'),
(54, 297, 'e6b1a0b6-b54f-430b-ad53-dc3350b89600', 'Access', '2026-08-27 09:46:46', '2026-08-27 01:50:05', 'User logout'),
(55, 15, '6ade5714-740e-4dbb-b733-97a0678b3db9', 'Access', '2026-08-27 09:50:14', '2026-08-27 02:01:55', 'User logout'),
(56, 305, '5067d94b-473e-41c2-bdf6-00eb9f0e39fe', 'Access', '2026-08-27 10:02:04', '2026-08-27 02:13:31', 'User logout'),
(57, 15, '34b1e0eb-6b89-46d6-a040-c501c0ce18f1', 'Access', '2026-08-27 10:13:42', '2026-08-27 02:14:53', 'User logout'),
(58, 305, 'aba02466-2edb-417d-894f-f8b8fc28f952', 'Access', '2026-08-27 10:17:37', '2026-08-27 02:24:10', 'User logout'),
(59, 15, '06295491-8774-442b-9503-10586bfcb8ed', 'Access', '2026-08-27 10:24:21', '2026-08-27 02:28:54', 'User logout'),
(60, 305, '8f92616d-8ba5-4024-a8d1-820c58c12c17', 'Access', '2026-08-27 10:29:01', '2026-08-27 03:15:51', 'User logout'),
(61, 15, '789d26eb-a4a9-4fce-9d43-e0dd1aaa9290', 'Access', '2026-08-27 11:16:01', '2026-08-27 03:18:15', 'User logout'),
(62, 498, 'e0324faa-9024-4a24-94a8-639072266341', 'Access', '2026-08-27 11:18:38', '2026-08-27 03:19:01', 'User logout'),
(63, 15, 'aa953c08-7fac-4e06-a392-820248eab322', 'Access', '2026-08-27 11:19:12', '2026-08-27 03:19:30', 'User logout'),
(64, 279, '084066fc-505a-4eb3-95bb-862867eafe22', 'Access', '2026-08-27 11:20:21', '2026-08-27 03:27:57', 'User logout'),
(65, 15, '40e38b7c-7fd7-466d-aac0-a9fdc5522919', 'Access', '2026-08-27 20:29:46', '2026-08-27 12:29:56', 'User logout'),
(67, 15, '758381ed-cc8e-4d04-9183-ad4c8195020f', 'Access', '2026-08-27 20:30:37', '2026-08-27 12:39:12', 'User logout'),
(68, 335, 'd36901a7-cfc4-4867-b6db-eb160aa43ebf', 'Access', '2026-08-27 20:39:25', '2026-08-27 12:39:31', 'User logout'),
(69, 15, '2588a9b0-a38d-4521-ba5f-9485dfafbd1f', 'Access', '2026-08-27 20:43:06', '2026-08-27 12:52:14', 'User logout'),
(70, 335, '8bfc9dd5-ebf1-431b-a36c-41cbb2784642', 'Access', '2026-08-27 20:53:51', '2026-08-27 12:55:01', 'User logout'),
(71, 405, '8fb8e2fe-16a0-4412-bb8f-4ef71f5fa3a4', 'Access', '2026-08-27 20:55:13', '2026-08-27 12:55:49', 'User logout'),
(72, 335, '884373a6-7ab5-4c74-b8bd-c4a315399846', 'Access', '2026-08-27 20:56:01', '2026-08-27 12:56:39', 'User logout'),
(73, 335, '1a759298-d13f-43eb-9c8e-8a5714d23a1a', 'Access', '2026-08-27 21:12:07', '2026-08-27 13:14:11', 'User logout'),
(74, 15, '4a90922a-e035-4a30-bbed-a8841040875e', 'Access', '2026-08-27 20:56:48', '2026-08-27 13:46:14', 'User logout'),
(75, 15, 'c1ab7148-65fa-407c-8c45-fdb33de5feaf', 'Access', '2026-08-27 22:08:17', '2026-08-27 14:08:51', 'User logout'),
(76, 298, 'aabb2037-076e-4e4a-986e-46be034f4913', 'Access', '2026-08-27 22:08:58', '2026-08-27 14:09:13', 'User logout'),
(77, 15, 'fadda147-e550-4354-ac6d-cd3315f3d3ce', 'Access', '2026-08-27 22:09:21', '2026-08-27 14:09:53', 'User logout'),
(78, 505, '2dfcfcbc-77a5-4c35-9673-34b13aa8fe9c', 'Access', '2026-08-27 22:10:00', '2026-08-27 14:10:08', 'User logout'),
(79, 15, 'b3be1df2-8ff4-40c1-a8fa-ecce817f0b4f', 'Access', '2026-08-27 22:10:16', '2026-08-27 14:10:31', 'User logout'),
(80, 343, 'cb4a10d1-3280-4a4a-8e2b-d6d05d42b0bd', 'Access', '2026-08-27 22:10:39', '2026-08-27 14:11:01', 'User logout'),
(81, 15, '2b2d89bf-cc68-48c7-a5a3-a4fab93cf084', 'Access', '2026-08-27 22:11:09', '2026-08-27 14:11:21', 'User logout'),
(82, 342, '31fce497-f285-4251-bf56-f82c8054b81a', 'Access', '2026-08-27 22:11:30', '2026-08-27 14:12:13', 'User logout'),
(83, 15, '870b4eca-5cfd-4cf9-8951-51868d8de4a7', 'Access', '2026-08-27 22:12:22', '2026-08-27 14:12:37', 'User logout'),
(84, 344, '51e0803a-63b0-4979-b5d9-4aeb038c79b8', 'Access', '2026-08-27 22:12:47', '2026-08-27 14:19:27', 'User logout'),
(85, 15, '9d95fff9-0f31-4612-b24e-78a759e95593', 'Access', '2026-08-27 22:20:25', '2026-08-27 14:21:03', 'User logout'),
(86, 297, 'f44e1345-ba31-4022-b1a1-ffa9b62842f4', 'Access', '2026-08-27 22:25:47', '2026-08-27 14:26:15', 'User logout'),
(87, 335, 'f49a5446-4735-43c8-aea7-67942a6bbab7', 'Access', '2026-08-27 22:26:26', '2026-08-27 14:27:52', 'User logout'),
(88, 335, '430a7426-b216-47c2-a0c5-4729f66101ff', 'Access', '2026-08-28 00:37:07', '2026-08-27 17:27:41', 'User logout'),
(89, 405, '09c25a8a-fc93-41c6-b44e-7cc6f09930a6', 'Access', '2026-08-28 01:27:55', '2026-08-27 18:16:24', 'User logout'),
(90, 405, 'e7d55b6a-6e5f-4547-86b6-43607d204b76', 'Access', '2026-08-29 18:23:53', '2026-08-29 10:24:25', 'User logout'),
(91, 15, '658a51a0-3a89-4d77-aeea-969cc3fe962b', 'Access', '2026-08-29 18:24:34', '2026-08-29 10:24:48', 'User logout'),
(92, 277, 'd1f2f670-be59-4e03-92f2-a5ff58eb9cfd', 'Access', '2026-08-29 18:24:58', '2026-08-29 10:31:23', 'User logout'),
(93, 15, '8c5f3328-f659-40f8-89b1-9ead83726fa0', 'Access', '2026-08-29 18:31:31', '2026-08-29 10:31:41', 'User logout'),
(94, 335, 'd6f4cada-7059-4a06-aad8-858860eed134', 'Access', '2026-08-29 18:31:50', '2026-08-29 10:33:22', 'User logout'),
(95, 15, '90a3ef62-494f-4a2b-aac2-88cf3615fbd1', 'Access', '2026-08-29 18:33:33', '2026-08-29 10:33:43', 'User logout'),
(96, 371, '0ea647be-d383-4c93-a2f8-b210703f4e41', 'Access', '2026-08-29 18:33:52', '2026-08-29 10:40:26', 'User logout'),
(97, 15, '0a47ad6d-1d11-4d78-be6d-42a956bef91d', 'Access', '2026-08-29 18:40:34', '2026-08-29 10:40:47', 'User logout'),
(98, 498, 'f7693849-4ed6-41b0-8570-acbb8d5ff0be', 'Access', '2026-08-29 18:40:55', '2026-08-29 10:49:12', 'User logout'),
(99, 15, 'cbcc7dee-897e-45e8-88c6-dc7c5333200c', 'Access', '2026-08-29 18:49:21', '2026-08-29 10:50:30', 'User logout'),
(100, 301, '3fd13590-f6e4-4be2-a385-f6b9278a8a1d', 'Access', '2026-08-29 18:50:39', '2026-08-29 11:08:44', 'User logout'),
(101, 15, '4a1f7832-665a-428f-9110-f59adef9b0d9', 'Access', '2026-08-29 19:08:57', '2026-08-29 11:09:13', 'User logout'),
(102, 337, '585f4280-e976-4a12-823e-77789b2835ab', 'Access', '2026-08-29 19:09:22', '2026-08-29 11:09:57', 'User logout'),
(103, 15, '22604949-bad7-4937-b67c-74ba13180954', 'Access', '2026-08-29 19:10:07', '2026-08-29 11:10:20', 'User logout'),
(104, 402, 'babbfd20-7992-4028-b74a-494ea02cb842', 'Access', '2026-08-29 19:10:29', '2026-08-29 12:24:25', 'User logout'),
(105, 15, 'c1bf734a-fede-4213-a4b4-5dc25d43f114', 'Access', '2026-08-29 20:24:56', '2026-08-29 12:25:17', 'User logout'),
(106, 504, '15f2a580-5ca8-45d6-8c76-dc13c4a4f0b0', 'Access', '2026-08-29 20:25:24', '2026-08-29 12:26:03', 'User logout'),
(107, 15, '47341599-fa02-46bf-a347-b0439fca6c73', 'Access', '2026-08-29 20:34:36', '2026-08-29 12:35:42', 'User logout'),
(108, 505, 'd8a4941b-dbdb-4941-8af6-8dcbb4b6cfb4', 'Access', '2026-08-29 20:36:23', '2026-08-29 12:36:27', 'User logout'),
(109, 15, '1845442e-dc2b-4cbb-a7ee-4d67c626cb90', 'Access', '2026-08-29 20:36:36', '2026-08-29 13:39:13', 'User logout'),
(110, 335, 'e6ef136a-a624-483a-bc57-5acbdc9b088e', 'Access', '2026-08-29 21:39:22', '2026-08-29 13:41:34', 'User logout'),
(111, 15, '854bd405-ea04-40d3-877d-6515dd2cef2a', 'Access', '2026-08-29 21:41:43', '2026-08-29 13:41:57', 'User logout'),
(112, 342, 'e8c1b669-912f-488c-93ed-488a6be3f627', 'Access', '2026-08-29 21:42:07', '2026-08-29 13:45:25', 'User logout'),
(113, 15, '7ded6ef0-b4ec-43eb-983d-805b29ae6193', 'Access', '2026-08-29 21:45:34', '2026-08-29 13:45:42', 'User logout'),
(114, 393, 'b6ff9549-4c70-4056-9132-d83809c9afa8', 'Access', '2026-08-29 21:45:54', '2026-08-29 13:46:32', 'User logout'),
(115, 15, 'bad7215f-bbdb-4a24-a1f1-7adeb3d13a91', 'Access', '2026-08-29 21:53:53', '2026-08-29 14:06:23', 'User logout'),
(116, 15, '5a45b0fa-5e47-4402-ad78-69c57470d456', 'Access', '2026-08-29 22:07:41', '2026-08-29 14:10:12', 'User logout'),
(117, 341, '648c0a32-7601-46a3-9b6c-3e28fb16b626', 'Access', '2026-08-29 22:10:23', '2026-08-29 14:10:49', 'User logout'),
(118, 507, 'c7ced6c9-e4fa-471b-8026-0e83b981c8a3', 'Access', '2026-08-29 22:11:06', '2026-08-29 14:11:10', 'User logout'),
(119, 15, '7c2f3510-cb5e-447c-87d3-b1b601fd0cb4', 'Access', '2026-08-29 22:12:00', '2026-08-29 14:31:59', 'User logout'),
(120, 405, '0a51139c-9168-4714-af0e-383cfb4dcbad', 'Access', '2026-08-29 22:57:49', '2026-08-29 14:58:04', 'User logout'),
(121, 15, '7b29b561-4a8b-4495-9691-2e195aeb7408', 'Access', '2026-08-30 02:32:42', '2026-08-29 18:35:40', 'User logout'),
(122, 15, 'aea9a885-3988-475f-8e80-e0902f375a5d', 'Access', '2026-08-30 02:36:26', '2026-08-29 18:36:38', 'User logout'),
(123, 15, '4bd3b515-8e77-46a3-8eac-3f0473c97ab4', 'Access', '2026-08-30 02:37:00', '2026-08-29 18:37:56', 'User logout'),
(124, 506, '418bda24-4ff8-43f3-b3b7-958800bb1628', 'Access', '2026-08-30 02:38:35', '2026-08-29 18:38:55', 'User logout'),
(125, 15, '964c3a97-7659-4c91-9ee1-f26fee25ce0e', 'Access', '2026-08-30 02:39:21', '2026-08-29 18:39:54', 'User logout'),
(126, 480, '3ccf09a0-9974-41c2-8402-0f253079c639', 'Access', '2026-08-30 02:40:03', '2026-08-29 18:40:49', 'User logout'),
(127, 15, 'b4fff6cf-338a-4360-b958-d87a4433fc2c', 'Access', '2026-08-30 02:40:57', '2026-08-29 18:42:05', 'User logout'),
(128, 15, '36c957b4-67a6-4c5e-90ec-d48f6814f341', 'Access', '2026-08-30 02:46:59', '2026-08-29 18:47:17', 'User logout'),
(129, 405, '117b333b-c158-4bd8-986c-be7edc7c3e03', 'Access', '2026-08-30 02:48:11', '2026-08-29 18:48:43', 'User logout'),
(130, 15, 'c19fdb22-5ce0-47bd-a206-d0a8ccc1f5b7', 'Access', '2026-08-30 04:09:07', '2026-08-29 20:09:22', 'User logout'),
(131, 499, '9e975d05-c6c8-49ba-8695-e001d9386ac6', 'Access', '2026-08-30 04:09:31', '2026-08-30 00:14:32', 'User logout'),
(132, 15, '53c037b8-55e6-4d43-8a36-e4ba37fbd42d', 'Access', '2026-08-30 08:14:49', '2026-08-30 00:16:56', 'User logout'),
(133, 15, 'c7c08e7d-f79e-46e8-8130-9f1788565752', 'Access', '2026-08-30 08:17:13', '2026-08-30 00:17:25', 'User logout'),
(134, 15, '1faf58cf-bc6d-40b8-b85c-c32f6418c783', 'Access', '2026-08-30 08:17:48', '2026-08-30 00:20:59', 'User logout'),
(135, 273, 'd7f04776-c1cd-4ae9-a1bf-937d95fa4c74', 'Access', '2026-08-30 08:21:07', '2026-08-30 00:21:19', 'User logout'),
(136, 15, '5a027a5a-ef06-4e96-a8fd-8e22f2997c3c', 'Access', '2026-08-30 08:21:31', '2026-08-30 00:22:09', 'User logout'),
(137, 277, 'c3f7923d-9f16-421a-99a5-b67d04f60532', 'Access', '2026-08-30 08:22:16', '2026-08-30 00:28:09', 'User logout'),
(138, 335, 'd46763d4-cb3f-4494-adf2-7d7b2f800bc9', 'Access', '2026-08-30 08:28:19', '2026-08-30 00:30:42', 'User logout'),
(139, 15, '14155ee0-72e2-4743-8bb7-3cfccf0137ef', 'Access', '2026-08-30 08:30:51', '2026-08-30 00:31:21', 'User logout'),
(140, 501, '2ba5c882-4d88-4dc4-98ab-b8c55e1ee4a2', 'Access', '2026-08-30 08:31:30', '2026-08-30 00:37:30', 'User logout'),
(141, 15, '883293a4-fdd8-4364-9340-693de50cd6e6', 'Access', '2026-08-30 08:37:40', '2026-08-30 00:38:12', 'User logout'),
(142, 337, '43650ba0-358e-4213-9006-9a020d00f8c6', 'Access', '2026-08-30 08:38:22', '2026-08-30 00:39:01', 'User logout'),
(143, 15, '0aa6370e-0b5f-4f65-9c3c-63f6da80f46e', 'Access', '2026-08-30 08:39:12', '2026-08-30 00:39:26', 'User logout'),
(144, 402, 'bdfa1ab5-ac19-4921-bf65-5d82dc7f7f5f', 'Access', '2026-08-30 08:39:36', '2026-08-30 00:50:14', 'User logout'),
(145, 15, '5eb771d5-c1d6-41d7-8ee1-51bae1109616', 'Access', '2026-08-30 08:50:23', '2026-08-30 00:57:06', 'User logout'),
(146, 15, 'dacd266c-76f4-43c6-939d-506b83c4372d', 'Access', '2026-08-30 08:57:22', '2026-08-30 00:57:56', 'User logout'),
(147, 402, '58271630-03b7-42ff-a078-a06a1eebefc6', 'Access', '2026-08-30 08:58:08', '2026-08-30 01:07:41', 'User logout'),
(148, 15, '2d3ac301-c121-47f9-82bb-34cf73b2bde8', 'Access', '2026-08-30 09:07:56', '2026-08-30 01:08:18', 'User logout'),
(149, 15, 'ce40c341-23fb-408a-9493-a21fe51ce52e', 'Access', '2026-08-30 09:08:38', '2026-08-30 01:18:44', 'User logout'),
(150, 306, 'ff988691-2563-49e4-9178-7611c9a18b12', 'Access', '2026-08-30 09:19:45', '2026-08-30 01:21:41', 'User logout'),
(151, 15, 'b4561774-5f29-40b6-a3ea-b2cb7d864ea9', 'Access', '2026-08-30 09:21:51', '2026-08-30 01:43:01', 'User logout'),
(152, 306, '012784cb-ebdd-4b3f-8b10-b7fc9c9516fd', 'Access', '2026-08-30 09:44:03', '2026-08-30 01:51:26', 'User logout'),
(153, 15, '42bab2e5-8f70-47f9-a25f-361e80404e35', 'Access', '2026-08-30 09:51:37', '2026-08-30 01:51:52', 'User logout'),
(154, 339, '7276548a-8450-460a-a0e2-a1c4f30bba40', 'Access', '2026-08-30 09:52:02', '2026-08-30 01:52:36', 'User logout'),
(155, 15, '7bee7cb4-4b93-4e27-b91d-12b242179cbc', 'Access', '2026-08-30 09:52:46', '2026-08-30 01:53:09', 'User logout'),
(156, 365, '0672d93b-3815-41f2-8324-122123234b0f', 'Access', '2026-08-30 09:53:20', '2026-08-30 01:55:41', 'User logout'),
(157, 15, 'dcb98a1f-439c-4a05-8522-bd16d9dfe030', 'Access', '2026-08-30 09:55:54', '2026-08-30 01:56:09', 'User logout'),
(158, 344, 'a1254c89-eaa6-442a-b001-bb23412c64e0', 'Access', '2026-08-30 09:56:21', '2026-08-30 01:56:57', 'User logout'),
(159, 335, '49b64cd8-d790-45d5-ae1e-eb15801f048e', 'Access', '2026-08-30 12:06:33', '2026-08-30 04:06:46', 'User logout'),
(160, 15, '29b9c675-2d46-4a22-90b3-e7a12e547de7', 'Access', '2026-08-30 12:06:53', '2026-08-30 04:07:05', 'User logout'),
(161, 15, 'bd52b275-b807-4ff7-853e-6036b2e73ec8', 'Access', '2026-08-30 16:44:27', '2026-08-30 08:44:55', 'User logout'),
(162, 15, '84194a9e-69ed-4379-8cbd-65e6b0436bf4', 'Access', '2026-08-30 16:45:19', '2026-08-30 10:01:36', 'User logout'),
(163, 335, '52337a41-9f24-4a0a-86a1-6baecbc4905d', 'Access', '2026-08-30 18:01:45', '2026-08-30 10:03:40', 'User logout'),
(164, 15, 'f28c183c-fe48-400e-a915-0f421af9fd53', 'Access', '2026-08-30 18:04:04', '2026-08-30 10:04:52', 'User logout'),
(165, 481, '2a5a0429-7837-4a33-b8c9-804f3764e643', 'Access', '2026-08-30 18:05:01', '2026-08-30 10:05:35', 'User logout'),
(166, 481, '323f71d7-ea8b-43fd-b123-13177c322f20', 'Access', '2026-08-30 18:05:48', '2026-08-30 10:06:25', 'User logout'),
(167, 505, '02f87b8b-ba49-491b-9442-a9074696136e', 'Access', '2026-08-30 18:07:20', '2026-08-30 10:13:54', 'User logout'),
(168, 15, 'b44b85f0-3cec-4919-936c-14bad762a39e', 'Access', '2026-08-30 18:14:06', '2026-08-30 10:14:21', 'User logout'),
(169, 338, 'e23a1791-f73c-4652-ad1b-840e4496f156', 'Access', '2026-08-30 18:14:33', '2026-08-30 10:15:52', 'User logout'),
(170, 15, 'ea676d8a-64e1-4bc7-8f4b-a10ac4fb9ae3', 'Access', '2026-08-30 18:16:01', '2026-08-30 10:16:09', 'User logout'),
(171, 410, '43491cc4-cdfc-4ec6-8bfe-fd3f8b2cf59c', 'Access', '2026-08-30 18:16:21', '2026-08-30 10:16:50', 'User logout'),
(172, 15, '22877149-a3b4-4b14-b752-899347cfbe9f', 'Access', '2026-08-30 18:18:29', '2026-08-30 10:18:44', 'User logout'),
(173, 307, '0f7d1461-2009-47a1-a3a5-e0d1321a434c', 'Access', '2026-08-30 18:18:54', '2026-08-30 10:22:12', 'User logout'),
(174, 15, 'a4f21243-140d-4d39-a63d-2c88b1d05711', 'Access', '2026-08-30 18:22:20', '2026-08-30 10:22:36', 'User logout'),
(175, 338, 'f24ec745-e07d-41cd-94b0-f6d613094689', 'Access', '2026-08-30 18:22:45', '2026-08-30 10:23:14', 'User logout'),
(176, 15, '23ad4ce3-0962-467f-a8b0-c1cbe1097c07', 'Access', '2026-08-30 18:23:25', '2026-08-30 10:23:37', 'User logout'),
(177, 395, 'ab1ff6d3-cf1b-489c-90c0-4d2b7abd0ebe', 'Access', '2026-08-30 18:23:48', '2026-08-30 10:25:32', 'User logout'),
(178, 15, '0e5ec6bc-daaa-4063-92d4-e3a018678a10', 'Access', '2026-08-30 21:37:44', '2026-08-30 13:38:22', 'User logout'),
(179, 507, 'fa4a1e01-c769-4990-97a3-4b1de1382743', 'Access', '2026-08-30 21:38:34', '2026-08-30 13:39:10', 'User logout'),
(180, 335, '810b7f23-91c1-4c06-91b1-219e856e5362', 'Access', '2026-08-31 00:13:33', '2026-08-30 16:14:43', 'User logout'),
(181, 15, 'b056255c-a7ad-4d0f-8580-68ca4974e234', 'Access', '2026-08-31 00:15:25', '2026-08-30 16:15:45', 'User logout'),
(182, 15, 'bc29c237-ea17-403d-8830-ebff3cfc34ef', 'Access', '2026-08-31 00:26:05', '2026-08-30 16:26:28', 'User logout'),
(183, 496, 'f666425f-c03d-47f9-8a53-28fc3fff8237', 'Access', '2026-08-31 00:26:36', '2026-08-30 16:27:09', 'User logout'),
(184, 335, '69cae411-f5bf-4cb7-aec0-600fa85f3798', 'Access', '2026-08-31 00:27:17', '2026-08-30 16:32:36', 'User logout'),
(185, 15, 'db00f7f4-fd44-4334-99dd-0a2bfbc7a4b8', 'Access', '2026-08-31 00:32:46', '2026-08-30 16:32:59', 'User logout'),
(186, 498, 'a8765461-56d1-449f-ba34-f935c67f3a29', 'Access', '2026-08-31 00:33:06', '2026-08-30 16:34:33', 'User logout'),
(187, 15, '2959d668-ff5d-4b86-9f70-0763a20cb121', 'Access', '2026-08-31 00:34:46', '2026-08-30 16:34:57', 'User logout'),
(188, 15, 'f06a0178-5ced-444f-9436-8b691af9c558', 'Access', '2026-08-31 08:28:46', '2026-08-31 00:29:13', 'User logout'),
(189, 501, '5578aa44-1b77-4ef1-8fb7-c661dd60c19b', 'Access', '2026-08-31 08:29:20', '2026-08-31 00:29:47', 'User logout'),
(190, 15, 'c82db642-9f52-4a19-9a81-4b7b1438d1c9', 'Access', '2026-08-31 08:29:56', '2026-08-31 00:30:05', 'User logout'),
(191, 402, '435d7511-a365-4d02-b6f1-01617e11e24b', 'Access', '2026-08-31 08:30:14', '2026-08-31 00:31:03', 'User logout');

-- --------------------------------------------------------

--
-- Table structure for table `roles`
--

CREATE TABLE `roles` (
  `role_id` bigint(20) UNSIGNED NOT NULL,
  `role_code` varchar(40) NOT NULL,
  `role_name` varchar(80) NOT NULL,
  `description` varchar(255) DEFAULT NULL,
  `active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `roles`
--

INSERT INTO `roles` (`role_id`, `role_code`, `role_name`, `description`, `active`, `created_at`) VALUES
(1, 'resident', 'Resident', 'Submit and track own maintenance tickets', 1, '2026-08-15 13:50:18'),
(2, 'apartment_admin', 'Apartment Admin', 'Manage maintenance workflow and review AI decisions', 1, '2026-08-15 13:50:18'),
(3, 'technician', 'Technician', 'Handle assigned maintenance jobs and repair updates', 1, '2026-08-15 13:50:18'),
(4, 'system_admin', 'System Admin', 'Manage users, configuration, audit and backup functions', 1, '2026-08-15 13:50:18');

-- --------------------------------------------------------

--
-- Table structure for table `role_permissions`
--

CREATE TABLE `role_permissions` (
  `role_permission_id` bigint(20) UNSIGNED NOT NULL,
  `role_id` bigint(20) UNSIGNED NOT NULL,
  `permission_id` bigint(20) UNSIGNED NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `role_permissions`
--

INSERT INTO `role_permissions` (`role_permission_id`, `role_id`, `permission_id`, `created_at`) VALUES
(1, 1, 14, '2026-08-15 13:50:18'),
(2, 1, 4, '2026-08-15 13:50:18'),
(3, 1, 1, '2026-08-15 13:50:18'),
(4, 1, 2, '2026-08-15 13:50:18'),
(5, 1, 5, '2026-08-15 13:50:18'),
(8, 2, 29, '2026-08-15 13:50:18'),
(9, 2, 16, '2026-08-15 13:50:18'),
(10, 2, 15, '2026-08-15 13:50:18'),
(11, 2, 17, '2026-08-15 13:50:18'),
(12, 2, 8, '2026-08-15 13:50:18'),
(13, 2, 10, '2026-08-15 13:50:18'),
(14, 2, 7, '2026-08-15 13:50:18'),
(15, 2, 3, '2026-08-15 13:50:18'),
(16, 2, 9, '2026-08-15 13:50:18'),
(17, 2, 6, '2026-08-15 13:50:18'),
(23, 3, 14, '2026-08-15 13:50:18'),
(24, 3, 13, '2026-08-15 13:50:18'),
(25, 3, 12, '2026-08-15 13:50:18'),
(26, 3, 11, '2026-08-15 13:50:18'),
(30, 4, 27, '2026-08-15 13:50:19'),
(31, 4, 26, '2026-08-15 13:50:19'),
(32, 4, 22, '2026-08-15 13:50:19'),
(33, 4, 21, '2026-08-15 13:50:19'),
(34, 4, 28, '2026-08-15 13:50:19'),
(35, 4, 29, '2026-08-15 13:50:19'),
(36, 4, 20, '2026-08-15 13:50:19'),
(37, 4, 19, '2026-08-15 13:50:19'),
(38, 4, 24, '2026-08-15 13:50:19'),
(39, 4, 23, '2026-08-15 13:50:19'),
(40, 4, 25, '2026-08-15 13:50:19'),
(41, 4, 18, '2026-08-15 13:50:19'),
(42, 2, 30, '2026-08-17 11:54:53'),
(43, 4, 30, '2026-08-17 11:54:53');

-- --------------------------------------------------------

--
-- Table structure for table `safety_rules`
--

CREATE TABLE `safety_rules` (
  `safety_rule_id` bigint(20) UNSIGNED NOT NULL,
  `category_id` bigint(20) UNSIGNED DEFAULT NULL,
  `rule_code` varchar(80) NOT NULL,
  `keyword_or_pattern` varchar(255) NOT NULL,
  `match_type` enum('Keyword','Phrase','Regex') NOT NULL DEFAULT 'Keyword',
  `language_type` enum('English','Sinhala','Singlish','Mixed','Any') NOT NULL DEFAULT 'Any',
  `score_weight` decimal(5,2) NOT NULL,
  `severity` enum('Low','Medium','High','Critical') NOT NULL,
  `warning_message` varchar(500) NOT NULL,
  `resident_action` varchar(500) DEFAULT NULL,
  `technician_action` varchar(500) DEFAULT NULL,
  `rule_version` varchar(40) NOT NULL DEFAULT '1.0.0',
  `active` tinyint(1) NOT NULL DEFAULT 1,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ;

--
-- Dumping data for table `safety_rules`
--

INSERT INTO `safety_rules` (`safety_rule_id`, `category_id`, `rule_code`, `keyword_or_pattern`, `match_type`, `language_type`, `score_weight`, `severity`, `warning_message`, `resident_action`, `technician_action`, `rule_version`, `active`, `created_by`, `updated_by`, `created_at`, `updated_at`) VALUES
(1, 1, 'RULE-SPARK-EN', 'spark', 'Keyword', 'English', 30.00, 'Critical', 'Electrical spark detected. Keep away from the affected area.', 'Do not touch the socket or exposed wiring. Move away and inform apartment management immediately.', 'Isolate power only when authorised and follow electrical safety procedure.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(2, 1, 'RULE-SMOKE-EN', 'smoke', 'Keyword', 'English', 35.00, 'Critical', 'Smoke may indicate an electrical or fire hazard.', 'Move to a safe location and notify apartment management immediately.', 'Inspect only after the area is made safe and follow emergency procedure.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(3, 1, 'RULE-SHOCK-EN', 'electric shock', 'Phrase', 'English', 40.00, 'Critical', 'Possible electric shock hazard detected.', 'Do not touch affected equipment or wet electrical areas.', 'Treat as an electrical emergency and use required protective equipment.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(4, 1, 'RULE-BURNING-EN', 'burning smell', 'Phrase', 'English', 30.00, 'Critical', 'Burning smell can indicate overheating or an electrical fault.', 'Keep away from the source and report immediately.', 'Check isolation and overheating risk before repair.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(5, 3, 'RULE-LIFT-STUCK-EN', 'lift stuck', 'Phrase', 'English', 35.00, 'Critical', 'Possible lift entrapment detected.', 'Do not force the lift doors. Use the building emergency contact process.', 'Attend using authorised lift rescue and maintenance procedure.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(6, 3, 'RULE-LIFT-TRAPPED-EN', 'trapped in lift', 'Phrase', 'English', 40.00, 'Critical', 'A person may be trapped inside a lift.', 'Keep communication with the trapped person if possible and contact building staff immediately.', 'Emergency lift response is required.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(7, 5, 'RULE-FLOOD-EN', 'flood', 'Keyword', 'English', 28.00, 'High', 'Flooding can create slip, contamination and electrical risks.', 'Avoid the flooded area, especially near electrical equipment.', 'Check water source and electrical proximity before work.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(8, 5, 'RULE-SEWAGE-EN', 'sewage', 'Keyword', 'English', 25.00, 'High', 'Sewage overflow can create a contamination hazard.', 'Avoid direct contact and keep children away from the affected area.', 'Use suitable protective equipment and isolate the affected area.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(9, 2, 'RULE-WATER-ELECTRIC-EN', 'water near electricity', 'Phrase', 'English', 35.00, 'Critical', 'Water near electrical equipment can create an electric shock hazard.', 'Do not enter or touch electrical equipment in the wet area.', 'Coordinate plumbing and electrical isolation before repair.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(10, NULL, 'RULE-GAS-EN', 'gas smell', 'Phrase', 'English', 40.00, 'Critical', 'Possible gas hazard detected.', 'Move away from the source, avoid creating sparks and notify building management immediately.', 'Follow the building gas safety response procedure.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(11, 1, 'RULE-SPARK-SINGLISH', 'spark wenawa', 'Phrase', 'Singlish', 30.00, 'Critical', 'Electrical spark wording detected.', 'Affected electrical area eka touch karanna epa. Safe thanakata yanna saha management ekata danwanna.', 'Use authorised electrical safety procedure before repair.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(12, 3, 'RULE-LIFT-STUCK-SINGLISH', 'lift eka stuck', 'Phrase', 'Singlish', 35.00, 'Critical', 'Possible lift entrapment wording detected.', 'Lift door eka force karanna epa. Building staff ekata immediately danwanna.', 'Attend as an emergency lift case.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(13, 5, 'RULE-WATER-SINGLISH', 'watura galanawa', 'Phrase', 'Singlish', 22.00, 'High', 'Major water flow wording detected.', 'Wet area walin ath wela inna saha electrical items walin watura ath karanna.', 'Inspect water source and nearby electrical risk.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(14, 1, 'RULE-SHOCK-SINGLISH', 'current eka wadinawa', 'Phrase', 'Singlish', 40.00, 'Critical', 'Possible electric shock wording detected.', 'Electrical item eka touch karanna epa. Safe thanakata yanna saha management ekata danwanna.', 'Treat as an electrical emergency.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(15, NULL, 'RULE-FIRE-SI', 'ගින්න', 'Keyword', 'Sinhala', 40.00, 'Critical', 'ගිනි අවදානමක් හඳුනාගෙන ඇත.', 'අවදානම් ස්ථානයෙන් ඉවත් වී ගොඩනැගිලි කළමනාකරණයට වහාම දැනුම් දෙන්න.', 'අදාළ ආරක්ෂක ක්‍රියාමාර්ග අනුව ප්‍රතිචාර දක්වන්න.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(16, 1, 'RULE-SMOKE-SI', 'දුම', 'Keyword', 'Sinhala', 35.00, 'Critical', 'දුම විදුලි හෝ ගිනි අවදානමක් විය හැක.', 'අවදානම් ස්ථානයෙන් ඉවත් වී වහාම දැනුම් දෙන්න.', 'ප්‍රදේශය ආරක්ෂිත බව තහවුරු කර පසුව පරීක්ෂා කරන්න.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(17, 3, 'RULE-LIFT-SI', 'ලිෆ්ට් එකේ හිර', 'Phrase', 'Sinhala', 40.00, 'Critical', 'ලිෆ්ට් එකක පුද්ගලයෙකු හිරවී ඇති බවක් පෙනේ.', 'දොර බලෙන් විවෘත කිරීමට උත්සාහ නොකර ගොඩනැගිලි කාර්ය මණ්ඩලයට වහාම දැනුම් දෙන්න.', 'හදිසි ලිෆ්ට් ප්‍රතිචාර ක්‍රියාපටිපාටිය අනුගමනය කරන්න.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(18, 5, 'RULE-FLOOD-SI', 'වතුර ගලනවා', 'Phrase', 'Sinhala', 25.00, 'High', 'වැඩි ජල ගැලීමක් හඳුනාගෙන ඇත.', 'තෙත් ප්‍රදේශයෙන් ඉවත් වී විදුලි උපකරණ වලින් වතුර ඈත් කරන්න.', 'ජල මූලාශ්‍රය සහ විදුලි අවදානම පරීක්ෂා කරන්න.', '1.0.0', 1, NULL, NULL, '2026-08-15 13:50:19', '2026-08-15 13:50:19');

-- --------------------------------------------------------

--
-- Table structure for table `skills`
--

CREATE TABLE `skills` (
  `skill_id` bigint(20) UNSIGNED NOT NULL,
  `skill_name` varchar(100) NOT NULL,
  `description` varchar(255) DEFAULT NULL,
  `active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `skills`
--

INSERT INTO `skills` (`skill_id`, `skill_name`, `description`, `active`, `created_at`, `updated_at`) VALUES
(1, 'Electrician', 'Electrical faults, wiring, sockets and power issues', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(2, 'Plumber', 'Water supply, leaks, pipes and drainage support', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(3, 'Lift Technician', 'Lift and elevator maintenance', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(4, 'AC Technician', 'Air conditioning and ventilation maintenance', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(5, 'Cleaner', 'Cleaning and common area maintenance', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(6, 'Pest Controller', 'Pest control and related treatment', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(7, 'Carpenter', 'Doors, windows, fittings and carpentry work', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(8, 'General Maintenance', 'General building maintenance and miscellaneous work', 1, '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(9, 'Fire and Safety Technician', 'Fire safety systems, smoke and emergency safety incidents', 1, '2026-08-17 11:54:53', '2026-08-17 11:54:53'),
(10, 'Gas Technician', 'Gas supply, gas smell and gas safety issues', 1, '2026-08-17 11:54:53', '2026-08-17 11:54:53'),
(11, 'Building Technician', 'Structural cracks, ceilings, walls, roofs and building fabric', 1, '2026-08-17 11:54:53', '2026-08-17 11:54:53'),
(12, 'Security Technician', 'Access control, gates, security doors and locks', 1, '2026-08-17 11:54:53', '2026-08-17 11:54:53');

-- --------------------------------------------------------

--
-- Table structure for table `system_settings`
--

CREATE TABLE `system_settings` (
  `setting_id` bigint(20) UNSIGNED NOT NULL,
  `setting_key` varchar(120) NOT NULL,
  `setting_value` text NOT NULL,
  `value_type` enum('String','Integer','Decimal','Boolean','JSON') NOT NULL DEFAULT 'String',
  `setting_group` varchar(80) NOT NULL DEFAULT 'General',
  `description` varchar(500) DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `system_settings`
--

INSERT INTO `system_settings` (`setting_id`, `setting_key`, `setting_value`, `value_type`, `setting_group`, `description`, `updated_by`, `updated_at`) VALUES
(2, 'emergency_risk_threshold', '86', 'Integer', 'Risk', 'Risk score at or above this value is Critical', 15, '2026-08-23 17:20:03'),
(3, 'high_risk_threshold', '61', 'Integer', 'Risk', 'Risk score at or above this value is High', NULL, '2026-08-15 13:50:19'),
(4, 'medium_risk_threshold', '31', 'Integer', 'Risk', 'Risk score at or above this value is Medium', NULL, '2026-08-15 13:50:19'),
(5, 'duplicate_similarity_threshold', '0.72', 'Decimal', 'AI', 'Cosine similarity threshold for duplicate candidates', 15, '2026-08-23 17:20:03'),
(6, 'low_confidence_threshold', '0.65', 'Decimal', 'AI', 'Prediction confidence below this value requires admin review', 15, '2026-08-23 17:20:03'),
(7, 'auto_emergency_assignment', 'true', 'Boolean', 'Assignment', 'Enable automatic assignment for Emergency or Critical tickets', 15, '2026-08-23 17:20:03'),
(8, 'email_alerts', 'false', 'Boolean', 'Notifications', 'Enable email adapter when configured', 15, '2026-08-29 18:34:15'),
(9, 'sms_alerts', 'false', 'Boolean', 'Notifications', 'Enable SMS adapter when configured', 15, '2026-08-23 17:20:03'),
(10, 'browser_alerts', 'true', 'Boolean', 'Notifications', 'Enable browser notifications when configured', 15, '2026-08-23 17:20:03'),
(11, 'allow_registration', 'true', 'Boolean', 'Authentication', 'Allow resident self registration', 15, '2026-08-24 00:40:21'),
(12, 'maintenance_mode', 'false', 'Boolean', 'General', 'Restrict normal access during maintenance', 15, '2026-08-26 20:47:36'),
(13, 'max_upload_mb', '5', 'Integer', 'Files', 'Maximum uploaded evidence file size', 15, '2026-08-23 17:45:48'),
(14, 'allowed_upload_types', '[\"image/jpeg\",\"image/png\",\"image/webp\"]', 'JSON', 'Files', 'Allowed image MIME types', NULL, '2026-08-15 13:50:19'),
(15, 'risk_priority_weight_emergency', '55', 'Integer', 'Risk', 'Base risk contribution for Emergency priority', NULL, '2026-08-15 13:50:19'),
(16, 'risk_priority_weight_high', '35', 'Integer', 'Risk', 'Base risk contribution for High priority', NULL, '2026-08-15 13:50:19'),
(17, 'risk_priority_weight_medium', '20', 'Integer', 'Risk', 'Base risk contribution for Medium priority', NULL, '2026-08-15 13:50:19'),
(18, 'risk_priority_weight_low', '8', 'Integer', 'Risk', 'Base risk contribution for Low priority', NULL, '2026-08-15 13:50:19'),
(19, 'duplicate_risk_increment', '8', 'Integer', 'Risk', 'Risk contribution when multiple related active reports exist', NULL, '2026-08-15 13:50:19'),
(20, 'history_risk_increment', '6', 'Integer', 'Risk', 'Risk contribution when the same asset or area has repeated issues', NULL, '2026-08-15 13:50:19'),
(21, 'night_time_risk_increment', '5', 'Integer', 'Risk', 'Optional time context increment for safety issues', NULL, '2026-08-15 13:50:19'),
(22, 'active_rule_version', '1.0.0', 'String', 'AI', 'Current safety rule configuration version', NULL, '2026-08-27 14:08:00'),
(23, 'data_retention_days', '365', 'Integer', 'Privacy', 'Retention period for operational records', NULL, '2026-08-27 14:08:00'),
(24, 'registration_requires_approval', 'true', 'Boolean', 'Authentication', 'Resident registration must be approved by an apartment or system administrator', 15, '2026-08-23 17:20:03'),
(26, 'system_name', 'HelaFixIt AI', 'String', 'General', 'Name shown for the maintenance system', 15, '2026-08-23 17:45:48'),
(27, 'allowed_image_types', 'jpg,jpeg,png,webp', 'String', 'Files', 'File extensions accepted by the maintenance upload interface', 15, '2026-08-23 17:45:48'),
(28, 'default_language', 'English', 'String', 'General', 'Default interface and resident language selection', 15, '2026-08-23 17:45:48'),
(29, 'technician_default_max_jobs', '4', 'Integer', 'Assignment', 'Default maximum active jobs when a technician account is created', 15, '2026-08-23 17:45:48'),
(30, 'notification_retention_days', '90', 'Integer', 'Notifications', 'Recommended number of days to retain routine notification records', 15, '2026-08-23 17:45:48'),
(31, 'apartment_name', 'Hela Residence', 'String', 'General', 'Display name of the managed apartment complex', 15, '2026-08-29 18:34:15');

-- --------------------------------------------------------

--
-- Table structure for table `technician_profiles`
--

CREATE TABLE `technician_profiles` (
  `technician_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `employee_code` varchar(50) NOT NULL,
  `assigned_building_id` bigint(20) UNSIGNED DEFAULT NULL,
  `availability` enum('Available','Busy','Off Duty','On Leave') NOT NULL DEFAULT 'Off Duty',
  `current_workload` smallint(5) UNSIGNED NOT NULL DEFAULT 0,
  `max_active_jobs` smallint(5) UNSIGNED NOT NULL DEFAULT 4,
  `emergency_eligible` tinyint(1) NOT NULL DEFAULT 0,
  `can_work_after_hours` tinyint(1) NOT NULL DEFAULT 0,
  `service_area` varchar(150) DEFAULT NULL,
  `years_experience` decimal(4,1) DEFAULT NULL,
  `average_response_minutes` smallint(5) UNSIGNED DEFAULT NULL,
  `special_equipment_notes` varchar(255) DEFAULT NULL,
  `rating` decimal(3,2) DEFAULT NULL,
  `active` tinyint(1) NOT NULL DEFAULT 1,
  `last_availability_change_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ;

--
-- Dumping data for table `technician_profiles`
--

INSERT INTO `technician_profiles` (`technician_id`, `user_id`, `employee_code`, `assigned_building_id`, `availability`, `current_workload`, `max_active_jobs`, `emergency_eligible`, `can_work_after_hours`, `service_area`, `years_experience`, `average_response_minutes`, `special_equipment_notes`, `rating`, `active`, `last_availability_change_at`, `created_at`, `updated_at`) VALUES
(152, 350, 'HFT-C-ELEC-01', 3, 'Available', 1, 5, 1, 1, 'Hela Residence Block C', 5.2, 15, 'Primary category: Electrical. Insulated electrical test kit, multimeter and PPE', 4.38, 1, '2026-08-20 08:30:00', '2026-08-20 08:30:00', '2026-08-27 12:45:39'),
(153, 351, 'HFT-A-OTHER-09', 1, 'Available', 0, 6, 1, 1, 'Hela Residence Block A', 8.6, 25, 'Primary category: Other. General maintenance toolkit and portable diagnostic equipment', 4.49, 1, '2026-08-19 09:50:00', '2026-08-19 09:50:00', '2026-08-27 12:45:39'),
(154, 352, 'HFT-D-PEST-07', 4, 'Available', 1, 5, 0, 0, 'Hela Residence Block D', 10.5, 35, 'Primary category: Pest Control. Pest treatment equipment and approved PPE', 4.30, 1, '2026-08-20 14:00:00', '2026-08-20 14:00:00', '2026-08-27 12:45:39'),
(155, 353, 'HFT-D-CARP-08', 4, 'Available', 0, 5, 0, 0, 'Hela Residence Block D', 3.2, 30, 'Primary category: Carpentry. Carpentry hand tools, drill and measuring equipment', 4.33, 1, '2026-08-20 14:10:00', '2026-08-20 14:10:00', '2026-08-27 12:45:39'),
(156, 354, 'HFT-C-PLUMB-02', 3, 'Available', 1, 5, 1, 1, 'Hela Residence Block C', 5.9, 20, 'Primary category: Plumbing. Pipe tools, leak detection kit and water isolation tools', 4.41, 1, '2026-08-20 08:40:00', '2026-08-20 08:40:00', '2026-08-27 12:45:39'),
(157, 355, 'HFT-A-PLUMB-02', 1, 'Available', 1, 5, 1, 1, 'Hela Residence Block A', 3.7, 20, 'Primary category: Plumbing. Pipe tools, leak detection kit and water isolation tools', 4.28, 1, '2026-08-19 08:40:00', '2026-08-19 08:40:00', '2026-08-27 12:45:39'),
(158, 356, 'HFT-C-LIFT-03', 3, 'Available', 1, 4, 1, 1, 'Hela Residence Block C', 6.6, 12, 'Primary category: Lift. Lift diagnostic kit and certified elevator safety equipment', 4.44, 1, '2026-08-20 08:50:00', '2026-08-20 08:50:00', '2026-08-27 12:45:39'),
(159, 357, 'HFT-D-OTHER-09', 4, 'Available', 0, 6, 1, 1, 'Hela Residence Block D', 3.9, 25, 'Primary category: Other. General maintenance toolkit and portable diagnostic equipment', 4.36, 1, '2026-08-20 14:20:00', '2026-08-20 14:20:00', '2026-08-27 12:45:39'),
(160, 358, 'HFT-B-AC-04', 2, 'Available', 0, 5, 0, 0, 'Hela Residence Block B', 6.2, 25, 'Primary category: Air Conditioning. HVAC gauges, refrigerant tools and electrical tester', 4.73, 1, '2026-08-19 13:30:00', '2026-08-19 13:30:00', '2026-08-27 12:45:39'),
(161, 359, 'HFT-B-GAS-11', 2, 'Available', 0, 4, 1, 1, 'Hela Residence Block B', 3.1, 10, 'Primary category: Gas. Gas detector, isolation tools and certified gas safety PPE', 4.29, 1, '2026-08-19 14:40:00', '2026-08-19 14:40:00', '2026-08-27 12:45:39'),
(162, 360, 'HFT-D-FIRE-10', 4, 'Available', 0, 4, 1, 1, 'Hela Residence Block D', 4.6, 10, 'Primary category: Fire and Safety. Fire alarm tester, extinguisher inspection kit and emergency PPE', 4.39, 1, '2026-08-20 14:30:00', '2026-08-20 14:30:00', '2026-08-27 12:45:39'),
(163, 361, 'HFT-A-AC-04', 1, 'Available', 1, 5, 0, 0, 'Hela Residence Block A', 5.1, 25, 'Primary category: Air Conditioning. HVAC gauges, refrigerant tools and electrical tester', 4.34, 1, '2026-08-19 09:00:00', '2026-08-19 09:00:00', '2026-08-27 12:45:39'),
(164, 362, 'HFT-B-STRUCT-12', 2, 'Available', 0, 4, 1, 1, 'Hela Residence Block B', 3.8, 30, 'Primary category: Structural. Crack inspection tools, moisture meter and structural assessment kit', 4.32, 1, '2026-08-19 14:50:00', '2026-08-19 14:50:00', '2026-08-27 12:45:39'),
(165, 363, 'HFT-D-GAS-11', 4, 'Available', 0, 4, 1, 1, 'Hela Residence Block D', 5.3, 10, 'Primary category: Gas. Gas detector, isolation tools and certified gas safety PPE', 4.42, 1, '2026-08-20 14:40:00', '2026-08-20 14:40:00', '2026-08-27 12:45:39'),
(166, 364, 'HFT-D-STRUCT-12', 4, 'Available', 1, 4, 1, 1, 'Hela Residence Block D', 6.0, 30, 'Primary category: Structural. Crack inspection tools, moisture meter and structural assessment kit', 4.45, 1, '2026-08-20 14:50:00', '2026-08-20 14:50:00', '2026-08-27 12:45:39'),
(167, 365, 'HFT-B-ELEC-01', 2, 'Available', 1, 5, 1, 1, 'Hela Residence Block B', 4.1, 15, 'Primary category: Electrical. Insulated electrical test kit, multimeter and PPE', 4.64, 1, '2026-08-19 13:00:00', '2026-08-19 13:00:00', '2026-08-30 01:51:18'),
(168, 366, 'HFT-D-SEC-13', 4, 'Available', 1, 5, 1, 1, 'Hela Residence Block D', 6.7, 20, 'Primary category: Security and Access. Access control tester, lock tools and security system toolkit', 4.48, 1, '2026-08-20 15:00:00', '2026-08-20 15:00:00', '2026-08-27 12:45:39'),
(169, 367, 'HFT-C-AC-04', 3, 'Available', 0, 5, 0, 0, 'Hela Residence Block C', 7.3, 25, 'Primary category: Air Conditioning. HVAC gauges, refrigerant tools and electrical tester', 4.47, 1, '2026-08-20 09:00:00', '2026-08-20 09:00:00', '2026-08-27 12:45:39'),
(170, 368, 'HFT-E-ELEC-01', 7, 'Available', 1, 5, 1, 1, 'Hela Residence Block E', 7.4, 15, 'Primary category: Electrical. Insulated electrical test kit, multimeter and PPE', 4.51, 1, '2026-08-21 08:30:00', '2026-08-21 08:30:00', '2026-08-27 12:45:39'),
(171, 369, 'HFT-C-DRAIN-05', 3, 'Available', 1, 5, 1, 1, 'Hela Residence Block C', 8.0, 18, 'Primary category: Drainage. Drain inspection tools, pump and protective equipment', 4.50, 1, '2026-08-20 09:10:00', '2026-08-20 09:10:00', '2026-08-27 12:45:39'),
(172, 370, 'HFT-E-PLUMB-02', 7, 'Available', 0, 5, 1, 1, 'Hela Residence Block E', 8.1, 20, 'Primary category: Plumbing. Pipe tools, leak detection kit and water isolation tools', 4.54, 1, '2026-08-21 08:40:00', '2026-08-21 08:40:00', '2026-08-27 12:45:39'),
(173, 371, 'HFT-A-DRAIN-05', 1, 'Available', 1, 5, 1, 1, 'Hela Residence Block A', 5.8, 18, 'Primary category: Drainage. Drain inspection tools, pump and protective equipment', 4.37, 1, '2026-08-19 09:10:00', '2026-08-19 09:10:00', '2026-08-29 10:32:58'),
(174, 372, 'HFT-B-CARP-08', 2, 'Available', 0, 5, 0, 0, 'Hela Residence Block B', 9.0, 30, 'Primary category: Carpentry. Carpentry hand tools, drill and measuring equipment', 4.85, 1, '2026-08-19 14:10:00', '2026-08-19 14:10:00', '2026-08-27 12:45:39'),
(175, 373, 'HFT-E-LIFT-03', 7, 'Available', 1, 4, 1, 1, 'Hela Residence Block E', 8.8, 12, 'Primary category: Lift. Lift diagnostic kit and certified elevator safety equipment', 4.57, 1, '2026-08-21 08:50:00', '2026-08-21 08:50:00', '2026-08-27 12:45:39'),
(176, 374, 'HFT-C-CLEAN-06', 3, 'Available', 0, 6, 0, 0, 'Hela Residence Block C', 8.7, 30, 'Primary category: Cleaning. Commercial cleaning equipment and spill response kit', 4.53, 1, '2026-08-20 09:20:00', '2026-08-20 09:20:00', '2026-08-27 12:45:39'),
(177, 375, 'HFT-B-SEC-13', 2, 'Available', 1, 5, 1, 1, 'Hela Residence Block B', 4.5, 20, 'Primary category: Security and Access. Access control tester, lock tools and security system toolkit', 4.35, 1, '2026-08-19 15:00:00', '2026-08-19 15:00:00', '2026-08-27 12:45:39'),
(178, 376, 'HFT-A-SEC-13', 1, 'Available', 0, 5, 1, 1, 'Hela Residence Block A', 3.4, 20, 'Primary category: Security and Access. Access control tester, lock tools and security system toolkit', 4.61, 1, '2026-08-19 10:30:00', '2026-08-19 10:30:00', '2026-08-27 12:45:39'),
(179, 377, 'HFT-E-AC-04', 7, 'Available', 0, 5, 0, 0, 'Hela Residence Block E', 9.5, 25, 'Primary category: Air Conditioning. HVAC gauges, refrigerant tools and electrical tester', 4.60, 1, '2026-08-21 09:00:00', '2026-08-21 09:00:00', '2026-08-27 12:45:39'),
(180, 378, 'HFT-C-PEST-07', 3, 'Available', 1, 5, 0, 0, 'Hela Residence Block C', 9.4, 35, 'Primary category: Pest Control. Pest treatment equipment and approved PPE', 4.56, 1, '2026-08-20 09:30:00', '2026-08-20 09:30:00', '2026-08-27 12:45:39'),
(181, 379, 'HFT-A-PEST-07', 1, 'Available', 0, 5, 0, 0, 'Hela Residence Block A', 7.2, 35, 'Primary category: Pest Control. Pest treatment equipment and approved PPE', 4.43, 1, '2026-08-19 09:30:00', '2026-08-19 09:30:00', '2026-08-27 12:45:39'),
(182, 380, 'HFT-C-CARP-08', 3, 'Available', 2, 5, 0, 0, 'Hela Residence Block C', 10.1, 30, 'Primary category: Carpentry. Carpentry hand tools, drill and measuring equipment', 4.59, 1, '2026-08-20 09:40:00', '2026-08-20 09:40:00', '2026-08-27 12:45:39'),
(183, 381, 'HFT-E-DRAIN-05', 7, 'Available', 1, 5, 1, 1, 'Hela Residence Block E', 10.2, 18, 'Primary category: Drainage. Drain inspection tools, pump and protective equipment', 4.63, 1, '2026-08-21 09:10:00', '2026-08-21 09:10:00', '2026-08-27 12:45:39'),
(184, 382, 'HFT-B-PEST-07', 2, 'Available', 0, 5, 0, 0, 'Hela Residence Block B', 8.3, 35, 'Primary category: Pest Control. Pest treatment equipment and approved PPE', 4.82, 1, '2026-08-19 14:00:00', '2026-08-19 14:00:00', '2026-08-27 12:45:39'),
(185, 383, 'HFT-A-GAS-11', 1, 'Available', 0, 4, 1, 1, 'Hela Residence Block A', 10.0, 10, 'Primary category: Gas. Gas detector, isolation tools and certified gas safety PPE', 4.55, 1, '2026-08-19 10:10:00', '2026-08-19 10:10:00', '2026-08-27 12:45:39'),
(186, 384, 'HFT-E-CLEAN-06', 7, 'Available', 0, 6, 0, 0, 'Hela Residence Block E', 10.9, 30, 'Primary category: Cleaning. Commercial cleaning equipment and spill response kit', 4.66, 1, '2026-08-21 09:20:00', '2026-08-21 09:20:00', '2026-08-27 12:45:39'),
(187, 385, 'HFT-B-FIRE-10', 2, 'Available', 0, 4, 1, 1, 'Hela Residence Block B', 10.4, 10, 'Primary category: Fire and Safety. Fire alarm tester, extinguisher inspection kit and emergency PPE', 4.26, 1, '2026-08-19 14:30:00', '2026-08-19 14:30:00', '2026-08-27 12:45:39'),
(188, 386, 'HFT-C-OTHER-09', 3, 'Available', 1, 6, 1, 1, 'Hela Residence Block C', 10.8, 25, 'Primary category: Other. General maintenance toolkit and portable diagnostic equipment', 4.62, 1, '2026-08-20 09:50:00', '2026-08-20 09:50:00', '2026-08-27 12:45:39'),
(189, 387, 'HFT-C-FIRE-10', 3, 'Available', 1, 4, 1, 1, 'Hela Residence Block C', 3.5, 10, 'Primary category: Fire and Safety. Fire alarm tester, extinguisher inspection kit and emergency PPE', 4.65, 1, '2026-08-20 10:00:00', '2026-08-20 10:00:00', '2026-08-27 12:45:39'),
(190, 388, 'HFT-E-PEST-07', 7, 'Available', 0, 5, 0, 0, 'Hela Residence Block E', 3.6, 35, 'Primary category: Pest Control. Pest treatment equipment and approved PPE', 4.69, 1, '2026-08-21 09:30:00', '2026-08-21 09:30:00', '2026-08-27 12:45:39'),
(191, 389, 'HFT-E-CARP-08', 7, 'Available', 0, 5, 0, 0, 'Hela Residence Block E', 4.3, 30, 'Primary category: Carpentry. Carpentry hand tools, drill and measuring equipment', 4.72, 1, '2026-08-21 09:40:00', '2026-08-21 09:40:00', '2026-08-27 12:45:39'),
(192, 390, 'HFT-C-GAS-11', 3, 'Available', 0, 4, 1, 1, 'Hela Residence Block C', 4.2, 10, 'Primary category: Gas. Gas detector, isolation tools and certified gas safety PPE', 4.68, 1, '2026-08-20 10:10:00', '2026-08-20 10:10:00', '2026-08-27 12:45:39'),
(193, 391, 'HFT-C-STRUCT-12', 3, 'Available', 0, 4, 1, 1, 'Hela Residence Block C', 4.9, 30, 'Primary category: Structural. Crack inspection tools, moisture meter and structural assessment kit', 4.71, 1, '2026-08-20 10:20:00', '2026-08-20 10:20:00', '2026-08-27 12:45:39'),
(194, 392, 'HFT-A-FIRE-10', 1, 'Available', 0, 4, 1, 1, 'Hela Residence Block A', 9.3, 10, 'Primary category: Fire and Safety. Fire alarm tester, extinguisher inspection kit and emergency PPE', 4.52, 1, '2026-08-19 10:00:00', '2026-08-19 10:00:00', '2026-08-27 12:45:39'),
(195, 393, 'HFT-E-OTHER-09', 7, 'Available', 1, 6, 1, 1, 'Hela Residence Block E', 5.0, 25, 'Primary category: Other. General maintenance toolkit and portable diagnostic equipment', 4.75, 1, '2026-08-21 09:50:00', '2026-08-21 09:50:00', '2026-08-29 13:45:04'),
(196, 394, 'HFT-C-SEC-13', 3, 'Available', 0, 5, 1, 1, 'Hela Residence Block C', 5.6, 20, 'Primary category: Security and Access. Access control tester, lock tools and security system toolkit', 4.74, 1, '2026-08-20 10:30:00', '2026-08-20 10:30:00', '2026-08-27 12:45:39'),
(197, 395, 'HFT-E-FIRE-10', 7, 'Available', 1, 4, 1, 1, 'Hela Residence Block E', 5.7, 10, 'Primary category: Fire and Safety. Fire alarm tester, extinguisher inspection kit and emergency PPE', 4.78, 1, '2026-08-21 10:00:00', '2026-08-21 10:00:00', '2026-08-30 10:22:04'),
(198, 396, 'HFT-B-LIFT-03', 2, 'Available', 0, 4, 1, 1, 'Hela Residence Block B', 5.5, 12, 'Primary category: Lift. Lift diagnostic kit and certified elevator safety equipment', 4.70, 1, '2026-08-19 13:20:00', '2026-08-19 13:20:00', '2026-08-27 12:45:39'),
(199, 397, 'HFT-A-CARP-08', 1, 'Available', 0, 5, 0, 0, 'Hela Residence Block A', 7.9, 30, 'Primary category: Carpentry. Carpentry hand tools, drill and measuring equipment', 4.46, 1, '2026-08-19 09:40:00', '2026-08-19 09:40:00', '2026-08-27 12:45:39'),
(200, 398, 'HFT-A-STRUCT-12', 1, 'Available', 0, 4, 1, 1, 'Hela Residence Block A', 10.7, 30, 'Primary category: Structural. Crack inspection tools, moisture meter and structural assessment kit', 4.58, 1, '2026-08-19 10:20:00', '2026-08-19 10:20:00', '2026-08-27 12:45:39'),
(201, 399, 'HFT-B-PLUMB-02', 2, 'Available', 0, 5, 1, 1, 'Hela Residence Block B', 4.8, 20, 'Primary category: Plumbing. Pipe tools, leak detection kit and water isolation tools', 4.67, 1, '2026-08-19 13:10:00', '2026-08-19 13:10:00', '2026-08-27 12:45:39'),
(202, 400, 'HFT-E-GAS-11', 7, 'Available', 0, 4, 1, 1, 'Hela Residence Block E', 6.4, 10, 'Primary category: Gas. Gas detector, isolation tools and certified gas safety PPE', 4.81, 1, '2026-08-21 10:10:00', '2026-08-21 10:10:00', '2026-08-27 12:45:39'),
(203, 401, 'HFT-B-CLEAN-06', 2, 'Available', 0, 6, 0, 0, 'Hela Residence Block B', 7.6, 30, 'Primary category: Cleaning. Commercial cleaning equipment and spill response kit', 4.79, 1, '2026-08-19 13:50:00', '2026-08-19 13:50:00', '2026-08-27 12:45:39'),
(204, 402, 'HFT-D-ELEC-01', 4, 'Available', 4, 5, 1, 1, 'Hela Residence Block D', 6.3, 15, 'Primary category: Electrical. Insulated electrical test kit, multimeter and PPE', 4.77, 1, '2026-08-20 13:00:00', '2026-08-20 13:00:00', '2026-08-30 16:34:18'),
(205, 403, 'HFT-B-OTHER-09', 2, 'Available', 0, 6, 1, 1, 'Hela Residence Block B', 9.7, 25, 'Primary category: Other. General maintenance toolkit and portable diagnostic equipment', 4.88, 1, '2026-08-19 14:20:00', '2026-08-19 14:20:00', '2026-08-27 12:45:39'),
(206, 404, 'HFT-A-LIFT-03', 1, 'Available', 1, 4, 1, 1, 'Hela Residence Block A', 4.4, 12, 'Primary category: Lift. Lift diagnostic kit and certified elevator safety equipment', 4.31, 1, '2026-08-19 08:50:00', '2026-08-19 08:50:00', '2026-08-30 00:29:12'),
(207, 405, 'HFT-A-ELEC-01', 1, 'On Leave', 0, 5, 1, 1, 'Hela Residence Block A', 3.0, 15, 'Primary category: Electrical. Insulated electrical test kit, multimeter and PPE', 4.25, 1, '2026-08-29 18:48:37', '2026-08-19 08:30:00', '2026-08-29 18:48:37'),
(208, 406, 'HFT-E-STRUCT-12', 7, 'Available', 0, 4, 1, 1, 'Hela Residence Block E', 7.1, 30, 'Primary category: Structural. Crack inspection tools, moisture meter and structural assessment kit', 4.84, 1, '2026-08-21 10:20:00', '2026-08-21 10:20:00', '2026-08-27 12:45:39'),
(209, 407, 'HFT-A-CLEAN-06', 1, 'Available', 0, 6, 0, 0, 'Hela Residence Block A', 6.5, 30, 'Primary category: Cleaning. Commercial cleaning equipment and spill response kit', 4.40, 1, '2026-08-19 09:20:00', '2026-08-19 09:20:00', '2026-08-27 12:45:39'),
(210, 408, 'HFT-D-PLUMB-02', 4, 'Available', 1, 5, 1, 1, 'Hela Residence Block D', 7.0, 20, 'Primary category: Plumbing. Pipe tools, leak detection kit and water isolation tools', 4.80, 1, '2026-08-20 13:10:00', '2026-08-20 13:10:00', '2026-08-27 12:45:39'),
(211, 409, 'HFT-B-DRAIN-05', 2, 'Available', 1, 5, 1, 1, 'Hela Residence Block B', 6.9, 18, 'Primary category: Drainage. Drain inspection tools, pump and protective equipment', 4.76, 1, '2026-08-19 13:40:00', '2026-08-19 13:40:00', '2026-08-27 12:45:39'),
(212, 410, 'HFT-E-SEC-13', 7, 'Available', 2, 5, 1, 1, 'Hela Residence Block E', 7.8, 20, 'Primary category: Security and Access. Access control tester, lock tools and security system toolkit', 4.87, 1, '2026-08-21 10:30:00', '2026-08-21 10:30:00', '2026-08-30 10:15:33'),
(213, 411, 'HFT-D-LIFT-03', 4, 'Available', 0, 4, 1, 1, 'Hela Residence Block D', 7.7, 12, 'Primary category: Lift. Lift diagnostic kit and certified elevator safety equipment', 4.83, 1, '2026-08-20 13:20:00', '2026-08-20 13:20:00', '2026-08-27 12:45:39'),
(214, 412, 'HFT-D-AC-04', 4, 'Available', 1, 5, 0, 0, 'Hela Residence Block D', 8.4, 25, 'Primary category: Air Conditioning. HVAC gauges, refrigerant tools and electrical tester', 4.86, 1, '2026-08-20 13:30:00', '2026-08-20 13:30:00', '2026-08-27 12:45:39'),
(215, 413, 'HFT-D-DRAIN-05', 4, 'Available', 1, 5, 1, 1, 'Hela Residence Block D', 9.1, 18, 'Primary category: Drainage. Drain inspection tools, pump and protective equipment', 4.89, 1, '2026-08-20 13:40:00', '2026-08-20 13:40:00', '2026-08-27 12:45:39'),
(216, 414, 'HFT-D-CLEAN-06', 4, 'Available', 2, 6, 0, 0, 'Hela Residence Block D', 9.8, 30, 'Primary category: Cleaning. Commercial cleaning equipment and spill response kit', 4.27, 1, '2026-08-20 13:50:00', '2026-08-20 13:50:00', '2026-08-27 12:45:39');

-- --------------------------------------------------------

--
-- Table structure for table `technician_skills`
--

CREATE TABLE `technician_skills` (
  `technician_skill_id` bigint(20) UNSIGNED NOT NULL,
  `technician_id` bigint(20) UNSIGNED NOT NULL,
  `skill_id` bigint(20) UNSIGNED NOT NULL,
  `skill_level` enum('Basic','Intermediate','Advanced','Expert') NOT NULL DEFAULT 'Intermediate',
  `verified` tinyint(1) NOT NULL DEFAULT 0,
  `experience_years` decimal(4,1) DEFAULT NULL,
  `is_primary` tinyint(1) NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `technician_skills`
--

INSERT INTO `technician_skills` (`technician_skill_id`, `technician_id`, `skill_id`, `skill_level`, `verified`, `experience_years`, `is_primary`, `created_at`) VALUES
(167, 152, 1, 'Advanced', 1, 5.2, 1, '2026-08-20 08:30:00'),
(168, 153, 8, 'Advanced', 1, 8.6, 1, '2026-08-19 09:50:00'),
(169, 154, 6, 'Advanced', 1, 10.5, 1, '2026-08-20 14:00:00'),
(170, 155, 7, 'Advanced', 1, 3.2, 1, '2026-08-20 14:10:00'),
(171, 156, 2, 'Advanced', 1, 5.9, 1, '2026-08-20 08:40:00'),
(172, 157, 2, 'Advanced', 1, 3.7, 1, '2026-08-19 08:40:00'),
(173, 158, 3, 'Expert', 1, 6.6, 1, '2026-08-20 08:50:00'),
(174, 159, 8, 'Advanced', 1, 3.9, 1, '2026-08-20 14:20:00'),
(175, 160, 4, 'Advanced', 1, 6.2, 1, '2026-08-19 13:30:00'),
(176, 161, 10, 'Expert', 1, 3.1, 1, '2026-08-19 14:40:00'),
(177, 162, 9, 'Expert', 1, 4.6, 1, '2026-08-20 14:30:00'),
(178, 163, 4, 'Advanced', 1, 5.1, 1, '2026-08-19 09:00:00'),
(179, 164, 11, 'Expert', 1, 3.8, 1, '2026-08-19 14:50:00'),
(180, 165, 10, 'Expert', 1, 5.3, 1, '2026-08-20 14:40:00'),
(181, 166, 11, 'Expert', 1, 6.0, 1, '2026-08-20 14:50:00'),
(182, 167, 1, 'Advanced', 1, 4.1, 1, '2026-08-19 13:00:00'),
(183, 168, 12, 'Advanced', 1, 6.7, 1, '2026-08-20 15:00:00'),
(184, 169, 4, 'Advanced', 1, 7.3, 1, '2026-08-20 09:00:00'),
(185, 170, 1, 'Advanced', 1, 7.4, 1, '2026-08-21 08:30:00'),
(186, 171, 2, 'Advanced', 1, 8.0, 1, '2026-08-20 09:10:00'),
(187, 172, 2, 'Advanced', 1, 8.1, 1, '2026-08-21 08:40:00'),
(188, 173, 2, 'Advanced', 1, 5.8, 1, '2026-08-19 09:10:00'),
(189, 174, 7, 'Advanced', 1, 9.0, 1, '2026-08-19 14:10:00'),
(190, 175, 3, 'Expert', 1, 8.8, 1, '2026-08-21 08:50:00'),
(191, 176, 5, 'Intermediate', 1, 8.7, 1, '2026-08-20 09:20:00'),
(192, 177, 12, 'Advanced', 1, 4.5, 1, '2026-08-19 15:00:00'),
(193, 178, 12, 'Advanced', 1, 3.4, 1, '2026-08-19 10:30:00'),
(194, 179, 4, 'Advanced', 1, 9.5, 1, '2026-08-21 09:00:00'),
(195, 180, 6, 'Advanced', 1, 9.4, 1, '2026-08-20 09:30:00'),
(196, 181, 6, 'Advanced', 1, 7.2, 1, '2026-08-19 09:30:00'),
(197, 182, 7, 'Advanced', 1, 10.1, 1, '2026-08-20 09:40:00'),
(198, 183, 2, 'Advanced', 1, 10.2, 1, '2026-08-21 09:10:00'),
(199, 184, 6, 'Advanced', 1, 8.3, 1, '2026-08-19 14:00:00'),
(200, 185, 10, 'Expert', 1, 10.0, 1, '2026-08-19 10:10:00'),
(201, 186, 5, 'Intermediate', 1, 10.9, 1, '2026-08-21 09:20:00'),
(202, 187, 9, 'Expert', 1, 10.4, 1, '2026-08-19 14:30:00'),
(203, 188, 8, 'Advanced', 1, 10.8, 1, '2026-08-20 09:50:00'),
(204, 189, 9, 'Expert', 1, 3.5, 1, '2026-08-20 10:00:00'),
(205, 190, 6, 'Advanced', 1, 3.6, 1, '2026-08-21 09:30:00'),
(206, 191, 7, 'Advanced', 1, 4.3, 1, '2026-08-21 09:40:00'),
(207, 192, 10, 'Expert', 1, 4.2, 1, '2026-08-20 10:10:00'),
(208, 193, 11, 'Expert', 1, 4.9, 1, '2026-08-20 10:20:00'),
(209, 194, 9, 'Expert', 1, 9.3, 1, '2026-08-19 10:00:00'),
(210, 195, 8, 'Advanced', 1, 5.0, 1, '2026-08-21 09:50:00'),
(211, 196, 12, 'Advanced', 1, 5.6, 1, '2026-08-20 10:30:00'),
(212, 197, 9, 'Expert', 1, 5.7, 1, '2026-08-21 10:00:00'),
(213, 198, 3, 'Expert', 1, 5.5, 1, '2026-08-19 13:20:00'),
(214, 199, 7, 'Advanced', 1, 7.9, 1, '2026-08-19 09:40:00'),
(215, 200, 11, 'Expert', 1, 10.7, 1, '2026-08-19 10:20:00'),
(216, 201, 2, 'Advanced', 1, 4.8, 1, '2026-08-19 13:10:00'),
(217, 202, 10, 'Expert', 1, 6.4, 1, '2026-08-21 10:10:00'),
(218, 203, 5, 'Intermediate', 1, 7.6, 1, '2026-08-19 13:50:00'),
(219, 204, 1, 'Advanced', 1, 6.3, 1, '2026-08-20 13:00:00'),
(220, 205, 8, 'Advanced', 1, 9.7, 1, '2026-08-19 14:20:00'),
(221, 206, 3, 'Expert', 1, 4.4, 1, '2026-08-19 08:50:00'),
(222, 207, 1, 'Advanced', 1, 3.0, 1, '2026-08-19 08:30:00'),
(223, 208, 11, 'Expert', 1, 7.1, 1, '2026-08-21 10:20:00'),
(224, 209, 5, 'Intermediate', 1, 6.5, 1, '2026-08-19 09:20:00'),
(225, 210, 2, 'Advanced', 1, 7.0, 1, '2026-08-20 13:10:00'),
(226, 211, 2, 'Advanced', 1, 6.9, 1, '2026-08-19 13:40:00'),
(227, 212, 12, 'Advanced', 1, 7.8, 1, '2026-08-21 10:30:00'),
(228, 213, 3, 'Expert', 1, 7.7, 1, '2026-08-20 13:20:00'),
(229, 214, 4, 'Advanced', 1, 8.4, 1, '2026-08-20 13:30:00'),
(230, 215, 2, 'Advanced', 1, 9.1, 1, '2026-08-20 13:40:00'),
(231, 216, 5, 'Intermediate', 1, 9.8, 1, '2026-08-20 13:50:00');

-- --------------------------------------------------------

--
-- Table structure for table `temporary_passwords`
--

CREATE TABLE `temporary_passwords` (
  `temporary_password_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `password_hash` varchar(255) NOT NULL,
  `expires_at` datetime NOT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `used_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `temporary_passwords`
--

INSERT INTO `temporary_passwords` (`temporary_password_id`, `user_id`, `password_hash`, `expires_at`, `created_by`, `created_at`, `used_at`) VALUES
(1, 306, 'pbkdf2:sha256:600000$GUVA4wuZkC7ZnQMS$486d982e85cae01dab06978988507d2b7fa324f7f2e792589eaa2d4f147e5206', '2026-08-31 01:42:42', 15, '2026-08-30 01:42:42', '2026-08-30 01:43:53'),
(2, 505, 'pbkdf2:sha256:600000$JyTfWf0bNDjI4Xvy$f736440685a33ed750c042711b7fc378bfeb60ab57947f539f7bfb801abebc82', '2026-08-31 10:05:24', 481, '2026-08-30 10:05:24', '2026-08-30 10:07:06');

-- --------------------------------------------------------

--
-- Table structure for table `ticket_assignments`
--

CREATE TABLE `ticket_assignments` (
  `assignment_id` bigint(20) UNSIGNED NOT NULL,
  `ticket_id` bigint(20) UNSIGNED NOT NULL,
  `technician_id` bigint(20) UNSIGNED NOT NULL,
  `prediction_id` bigint(20) UNSIGNED DEFAULT NULL,
  `assignment_method` enum('Manual','Auto Emergency','Reassignment') NOT NULL,
  `assigned_by` bigint(20) UNSIGNED DEFAULT NULL,
  `assigned_at` datetime NOT NULL DEFAULT current_timestamp(),
  `accepted_at` datetime DEFAULT NULL,
  `declined_at` datetime DEFAULT NULL,
  `started_at` datetime DEFAULT NULL,
  `completed_at` datetime DEFAULT NULL,
  `assignment_status` enum('Assigned','Accepted','Declined','In Progress','On Hold','Completed','Cancelled','Reassigned') NOT NULL DEFAULT 'Assigned',
  `assignment_score` decimal(5,2) DEFAULT NULL,
  `assignment_reason` varchar(1000) DEFAULT NULL,
  `decline_reason` varchar(1000) DEFAULT NULL,
  `admin_override` tinyint(1) NOT NULL DEFAULT 0,
  `override_reason` varchar(1000) DEFAULT NULL,
  `is_current` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ;

--
-- Dumping data for table `ticket_assignments`
--

INSERT INTO `ticket_assignments` (`assignment_id`, `ticket_id`, `technician_id`, `prediction_id`, `assignment_method`, `assigned_by`, `assigned_at`, `accepted_at`, `declined_at`, `started_at`, `completed_at`, `assignment_status`, `assignment_score`, `assignment_reason`, `decline_reason`, `admin_override`, `override_reason`, `is_current`, `created_at`, `updated_at`) VALUES
(95, 67, 157, 97, 'Manual', 335, '2026-08-23 09:00:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching PLUMB technician for Block A after apartment admin review.', NULL, 0, NULL, 1, '2026-08-23 09:00:00', '2026-08-23 09:00:00'),
(96, 68, 163, 98, 'Manual', 335, '2026-08-22 15:15:00', '2026-08-22 15:40:00', NULL, '2026-08-23 09:10:00', NULL, 'In Progress', 95.00, 'Assigned to the matching AC technician for Block A after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 15:15:00', '2026-08-23 09:10:00'),
(97, 69, 207, 99, 'Manual', 335, '2026-08-21 13:35:00', '2026-08-21 13:42:00', NULL, '2026-08-21 13:45:00', '2026-08-21 14:25:00', 'Completed', 95.00, 'Assigned to the matching ELEC technician for Block A after apartment admin review.', NULL, 0, NULL, 1, '2026-08-21 13:35:00', '2026-08-21 14:25:00'),
(98, 72, 177, 102, 'Manual', 339, '2026-08-23 09:10:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching SEC technician for Block B after apartment admin review.', NULL, 0, NULL, 1, '2026-08-23 09:10:00', '2026-08-23 09:10:00'),
(99, 73, 211, 103, 'Manual', 339, '2026-08-22 15:25:00', '2026-08-22 15:45:00', NULL, '2026-08-23 09:25:00', NULL, 'In Progress', 95.00, 'Assigned to the matching DRAIN technician for Block B after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 15:25:00', '2026-08-23 09:25:00'),
(100, 74, 203, 104, 'Manual', 339, '2026-08-21 13:50:00', '2026-08-21 13:58:00', NULL, '2026-08-21 14:00:00', '2026-08-21 14:35:00', 'Completed', 95.00, 'Assigned to the matching CLEAN technician for Block B after apartment admin review.', NULL, 0, NULL, 1, '2026-08-21 13:50:00', '2026-08-21 14:35:00'),
(101, 77, 182, 107, 'Manual', 336, '2026-08-23 09:20:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching CARP technician for Block C after apartment admin review.', NULL, 0, NULL, 1, '2026-08-23 09:20:00', '2026-08-23 09:20:00'),
(102, 78, 156, 108, 'Manual', 336, '2026-08-22 15:40:00', '2026-08-22 16:00:00', NULL, '2026-08-23 09:40:00', NULL, 'In Progress', 95.00, 'Assigned to the matching PLUMB technician for Block C after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 15:40:00', '2026-08-23 09:40:00'),
(103, 79, 169, 109, 'Manual', 336, '2026-08-21 14:05:00', '2026-08-21 14:13:00', NULL, '2026-08-21 14:15:00', '2026-08-21 15:00:00', 'Completed', 95.00, 'Assigned to the matching AC technician for Block C after apartment admin review.', NULL, 0, NULL, 1, '2026-08-21 14:05:00', '2026-08-21 15:00:00'),
(104, 82, 216, 112, 'Manual', 337, '2026-08-23 09:30:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching CLEAN technician for Block D after apartment admin review.', NULL, 0, NULL, 1, '2026-08-23 09:30:00', '2026-08-23 09:30:00'),
(105, 83, 154, 113, 'Manual', 337, '2026-08-22 15:55:00', '2026-08-22 16:15:00', NULL, '2026-08-23 09:55:00', NULL, 'In Progress', 95.00, 'Assigned to the matching PEST technician for Block D after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 15:55:00', '2026-08-23 09:55:00'),
(106, 84, 166, 114, 'Manual', 337, '2026-08-21 14:20:00', '2026-08-21 14:28:00', NULL, '2026-08-21 14:30:00', '2026-08-21 15:20:00', 'Completed', 95.00, 'Assigned to the matching STRUCT technician for Block D after apartment admin review.', NULL, 0, NULL, 1, '2026-08-21 14:20:00', '2026-08-21 15:20:00'),
(107, 87, 170, 117, 'Manual', 338, '2026-08-23 09:40:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching ELEC technician for Block E after apartment admin review.', NULL, 0, NULL, 1, '2026-08-23 09:40:00', '2026-08-23 09:40:00'),
(108, 88, 212, 118, 'Manual', 338, '2026-08-22 16:10:00', '2026-08-22 16:30:00', NULL, '2026-08-23 10:10:00', NULL, 'In Progress', 95.00, 'Assigned to the matching SEC technician for Block E after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 16:10:00', '2026-08-23 10:10:00'),
(109, 89, 172, 119, 'Manual', 338, '2026-08-21 14:35:00', '2026-08-21 14:43:00', NULL, '2026-08-21 14:45:00', '2026-08-21 15:30:00', 'Completed', 95.00, 'Assigned to the matching PLUMB technician for Block E after apartment admin review.', NULL, 0, NULL, 1, '2026-08-21 14:35:00', '2026-08-21 15:30:00'),
(110, 92, 183, 122, 'Manual', 338, '2026-08-20 09:50:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching DRAIN technician for Block E after apartment admin review.', NULL, 0, NULL, 1, '2026-08-20 09:50:00', '2026-08-20 09:50:00'),
(126, 118, 182, 141, 'Manual', 336, '2026-08-22 10:20:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching CARP technician for Block C after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 10:20:00', '2026-08-22 10:20:00'),
(127, 112, 158, 143, 'Manual', 336, '2026-08-22 08:38:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching LIFT technician for Block C after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 08:38:00', '2026-08-22 08:38:00'),
(128, 113, 171, 144, 'Manual', 336, '2026-08-22 08:55:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching DRAIN technician for Block C after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 08:55:00', '2026-08-22 08:55:00'),
(129, 114, 189, 145, 'Manual', 336, '2026-08-22 09:12:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching FIRE technician for Block C after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 09:12:00', '2026-08-22 09:12:00'),
(130, 115, 152, 146, 'Manual', 336, '2026-08-22 09:29:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching ELEC technician for Block C after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 09:29:00', '2026-08-22 09:29:00'),
(131, 116, 180, 147, 'Manual', 336, '2026-08-22 09:46:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching PEST technician for Block C after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 09:46:00', '2026-08-22 09:46:00'),
(132, 117, 188, 148, 'Manual', 336, '2026-08-22 10:03:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching OTHER technician for Block C after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 10:03:00', '2026-08-22 10:03:00'),
(133, 119, 210, 149, 'Manual', 337, '2026-08-22 10:37:00', NULL, NULL, NULL, NULL, 'Assigned', 95.00, 'Assigned to the matching PLUMB technician for Block D after apartment admin review.', NULL, 0, NULL, 1, '2026-08-22 10:37:00', '2026-08-22 10:37:00'),
(134, 120, 204, 150, 'Manual', 337, '2026-08-21 09:38:00', '2026-08-21 09:47:00', NULL, '2026-08-21 09:59:00', NULL, 'In Progress', 95.00, 'Assigned to the matching ELEC technician for Block D after apartment admin review.', NULL, 0, NULL, 1, '2026-08-21 09:38:00', '2026-08-21 09:59:00'),
(135, 121, 168, 151, 'Manual', 337, '2026-08-21 09:55:00', '2026-08-21 10:04:00', NULL, '2026-08-21 10:16:00', NULL, 'In Progress', 95.00, 'Assigned to the matching SEC technician for Block D after apartment admin review.', NULL, 0, NULL, 1, '2026-08-21 09:55:00', '2026-08-21 10:16:00'),
(136, 122, 214, 152, 'Manual', 337, '2026-08-21 10:12:00', '2026-08-21 10:21:00', NULL, '2026-08-21 10:33:00', NULL, 'In Progress', 95.00, 'Assigned to the matching AC technician for Block D after apartment admin review.', NULL, 0, NULL, 1, '2026-08-21 10:12:00', '2026-08-21 10:33:00'),
(137, 123, 166, 153, 'Manual', 337, '2026-08-21 10:29:00', '2026-08-21 10:38:00', NULL, '2026-08-21 10:50:00', NULL, 'In Progress', 95.00, 'Assigned to the matching STRUCT technician for Block D after apartment admin review.', NULL, 0, NULL, 1, '2026-08-21 10:29:00', '2026-08-21 10:50:00'),
(138, 124, 216, 154, 'Manual', 337, '2026-08-21 10:46:00', '2026-08-21 10:55:00', NULL, '2026-08-21 11:07:00', NULL, 'In Progress', 95.00, 'Assigned to the matching CLEAN technician for Block D after apartment admin review.', NULL, 0, NULL, 1, '2026-08-21 10:46:00', '2026-08-21 11:07:00'),
(139, 125, 215, 155, 'Manual', 337, '2026-08-21 11:03:00', '2026-08-21 11:12:00', NULL, '2026-08-21 11:24:00', NULL, 'In Progress', 95.00, 'Assigned to the matching DRAIN technician for Block D after apartment admin review.', NULL, 0, NULL, 1, '2026-08-21 11:03:00', '2026-08-21 11:24:00'),
(140, 126, 175, 156, 'Manual', 338, '2026-08-21 11:20:00', '2026-08-21 11:29:00', NULL, '2026-08-21 11:41:00', NULL, 'In Progress', 95.00, 'Assigned to the matching LIFT technician for Block E after apartment admin review.', NULL, 0, NULL, 1, '2026-08-21 11:20:00', '2026-08-21 11:41:00'),
(141, 127, 202, 157, 'Manual', 338, '2026-08-18 11:01:00', '2026-08-18 11:12:00', NULL, '2026-08-18 11:24:00', '2026-08-18 12:44:00', 'Completed', 95.00, 'Assigned to the matching GAS technician for Block E after apartment admin review.', NULL, 0, NULL, 1, '2026-08-18 11:01:00', '2026-08-18 12:44:00'),
(142, 128, 197, 158, 'Manual', 338, '2026-08-18 09:02:00', '2026-08-18 09:13:00', NULL, '2026-08-18 09:25:00', '2026-08-18 10:15:00', 'Completed', 95.00, 'Assigned to the matching FIRE technician for Block E after apartment admin review.', NULL, 0, NULL, 1, '2026-08-18 09:02:00', '2026-08-18 10:15:00'),
(143, 129, 191, 159, 'Manual', 338, '2026-08-18 09:19:00', '2026-08-18 09:30:00', NULL, '2026-08-18 09:42:00', '2026-08-18 10:47:00', 'Completed', 95.00, 'Assigned to the matching CARP technician for Block E after apartment admin review.', NULL, 0, NULL, 1, '2026-08-18 09:19:00', '2026-08-18 10:47:00'),
(144, 130, 172, 160, 'Manual', 338, '2026-08-18 09:36:00', '2026-08-18 09:47:00', NULL, '2026-08-18 09:59:00', '2026-08-18 11:19:00', 'Completed', 95.00, 'Assigned to the matching PLUMB technician for Block E after apartment admin review.', NULL, 0, NULL, 1, '2026-08-18 09:36:00', '2026-08-18 11:19:00'),
(145, 131, 190, 161, 'Manual', 338, '2026-08-18 09:53:00', '2026-08-18 10:04:00', NULL, '2026-08-18 10:16:00', '2026-08-18 11:06:00', 'Completed', 95.00, 'Assigned to the matching PEST technician for Block E after apartment admin review.', NULL, 0, NULL, 1, '2026-08-18 09:53:00', '2026-08-18 11:06:00'),
(146, 132, 212, 162, 'Manual', 338, '2026-08-18 10:10:00', '2026-08-18 10:21:00', NULL, '2026-08-18 10:33:00', '2026-08-18 11:38:00', 'Completed', 95.00, 'Assigned to the matching SEC technician for Block E after apartment admin review.', NULL, 0, NULL, 1, '2026-08-18 10:10:00', '2026-08-18 11:38:00'),
(147, 133, 171, 163, 'Manual', 336, '2026-08-26 18:57:50', '2026-08-26 18:59:04', NULL, '2026-08-26 19:00:09', '2026-08-26 19:02:08', 'Completed', NULL, 'Manual assignment by apartment admin.', NULL, 0, NULL, 1, '2026-08-26 18:57:50', '2026-08-29 13:38:14'),
(148, 194, 173, 224, 'Manual', 335, '2026-08-29 10:32:58', '2026-08-29 10:34:13', NULL, '2026-08-29 10:36:11', NULL, 'In Progress', NULL, 'Manual assignment by apartment admin.', NULL, 0, NULL, 1, '2026-08-29 10:32:58', '2026-08-29 13:38:14'),
(149, 195, 204, 225, 'Auto Emergency', NULL, '2026-08-29 11:08:31', NULL, NULL, NULL, NULL, 'Assigned', 99.68, 'Automatic emergency assignment based on required skill, availability, workload and emergency eligibility.', NULL, 0, NULL, 1, '2026-08-29 11:08:31', '2026-08-29 11:08:31'),
(150, 193, 195, NULL, 'Manual', 342, '2026-08-29 13:45:04', '2026-08-29 13:46:03', NULL, NULL, NULL, 'Accepted', NULL, 'Manual assignment by apartment admin.', NULL, 0, NULL, 1, '2026-08-29 13:45:04', '2026-08-29 13:46:03'),
(151, 196, 206, NULL, 'Manual', 335, '2026-08-30 00:29:12', NULL, NULL, NULL, NULL, 'Assigned', NULL, 'Manual assignment by apartment admin.', NULL, 0, NULL, 1, '2026-08-30 00:29:12', '2026-08-30 00:29:12'),
(152, 197, 204, 228, 'Auto Emergency', NULL, '2026-08-30 00:37:09', NULL, NULL, NULL, NULL, 'Assigned', 96.68, 'Automatic emergency assignment based on required skill, availability, workload and emergency eligibility.', NULL, 0, NULL, 1, '2026-08-30 00:37:09', '2026-08-30 00:37:09'),
(153, 198, 167, 229, 'Auto Emergency', NULL, '2026-08-30 01:51:18', '2026-08-30 01:54:18', NULL, '2026-08-30 01:54:46', NULL, 'In Progress', 100.00, 'Automatic emergency assignment based on required skill, availability, workload and emergency eligibility.', NULL, 0, NULL, 1, '2026-08-30 01:51:18', '2026-08-30 01:54:46'),
(154, 199, 212, NULL, 'Manual', 338, '2026-08-30 10:15:33', NULL, NULL, NULL, NULL, 'Assigned', NULL, 'Manual assignment by apartment admin.', NULL, 0, NULL, 1, '2026-08-30 10:15:33', '2026-08-30 10:15:33'),
(155, 200, 197, 231, 'Auto Emergency', NULL, '2026-08-30 10:22:04', NULL, NULL, NULL, NULL, 'Assigned', 100.00, 'Automatic emergency assignment based on required skill, availability, workload and emergency eligibility.', NULL, 0, NULL, 1, '2026-08-30 10:22:04', '2026-08-30 10:22:04'),
(156, 201, 204, 232, 'Auto Emergency', NULL, '2026-08-30 16:34:18', '2026-08-30 16:35:23', NULL, NULL, NULL, 'Accepted', 93.68, 'Automatic emergency assignment based on required skill, availability, workload and emergency eligibility.', NULL, 0, NULL, 1, '2026-08-30 16:34:18', '2026-08-30 16:35:23');

--
-- Triggers `ticket_assignments`
--
DELIMITER $$
CREATE TRIGGER `trg_assignment_workload_after_delete` AFTER DELETE ON `ticket_assignments` FOR EACH ROW BEGIN
    IF OLD.is_current = TRUE AND OLD.assignment_status IN ('Assigned','Accepted','In Progress','On Hold') THEN
        UPDATE technician_profiles
        SET current_workload = GREATEST(current_workload - 1, 0)
        WHERE technician_id = OLD.technician_id;
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_assignment_workload_after_insert` AFTER INSERT ON `ticket_assignments` FOR EACH ROW BEGIN
    IF NEW.is_current = TRUE AND NEW.assignment_status IN ('Assigned','Accepted','In Progress','On Hold') THEN
        UPDATE technician_profiles
        SET current_workload = current_workload + 1
        WHERE technician_id = NEW.technician_id;
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_assignment_workload_after_update` AFTER UPDATE ON `ticket_assignments` FOR EACH ROW BEGIN
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
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `ticket_attachments`
--

CREATE TABLE `ticket_attachments` (
  `attachment_id` bigint(20) UNSIGNED NOT NULL,
  `ticket_id` bigint(20) UNSIGNED NOT NULL,
  `update_id` bigint(20) UNSIGNED DEFAULT NULL,
  `uploaded_by` bigint(20) UNSIGNED DEFAULT NULL,
  `attachment_type` enum('Issue Photo','Progress Photo','Completion Proof','Document','Other') NOT NULL DEFAULT 'Other',
  `original_file_name` varchar(255) NOT NULL,
  `stored_file_name` varchar(255) NOT NULL,
  `storage_path` varchar(500) NOT NULL,
  `mime_type` varchar(100) NOT NULL,
  `file_size_bytes` bigint(20) UNSIGNED NOT NULL,
  `checksum_sha256` char(64) DEFAULT NULL,
  `resident_visible` tinyint(1) NOT NULL DEFAULT 1,
  `uploaded_at` datetime NOT NULL DEFAULT current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `ticket_attachments`
--

INSERT INTO `ticket_attachments` (`attachment_id`, `ticket_id`, `update_id`, `uploaded_by`, `attachment_type`, `original_file_name`, `stored_file_name`, `storage_path`, `mime_type`, `file_size_bytes`, `checksum_sha256`, `resident_visible`, `uploaded_at`, `deleted_at`) VALUES
(1, 133, NULL, 300, 'Issue Photo', 'img002.jpg', '95dc11f04f7e4583b0b6dea01ab92c71.jpg', 'tickets/133/95dc11f04f7e4583b0b6dea01ab92c71.jpg', 'image/jpeg', 3956239, '082cdf33dec469fb99ca16ab5467e16dca76d683231219ed88012df2e39322dd', 1, '2026-08-26 18:44:33', NULL),
(2, 194, NULL, 277, 'Issue Photo', 'img0017642026.jpg', '0bcb4d00443d47cd8ea970ecc1d2dd75.jpg', 'tickets/194/0bcb4d00443d47cd8ea970ecc1d2dd75.jpg', 'image/jpeg', 3428398, 'b4ffa37c4ab8f186360a9b354266f1472c601e81c05b110e978382ebdf28cd72', 1, '2026-08-29 10:31:11', NULL),
(3, 195, NULL, 301, 'Issue Photo', 'img20260824568521.jpg', '0d4eb6cb1a6049d68dd51f30316ab94e.jpg', 'tickets/195/0d4eb6cb1a6049d68dd51f30316ab94e.jpg', 'image/jpeg', 3023102, 'afea6bfb6159719dd230ef9f0ea919308ff01475abff63c6c1635c298274fdc1', 1, '2026-08-29 11:08:29', NULL),
(4, 197, NULL, 501, 'Issue Photo', 'img0234522026.jpg', '8a2d9bde26a54a078712eae13598f2a9.jpg', 'tickets/197/8a2d9bde26a54a078712eae13598f2a9.jpg', 'image/jpeg', 2976723, 'fbc0eb37314152b4f17961f35646e3c1d41ad0a69d4e116413606d066887cc52', 1, '2026-08-30 00:37:08', NULL),
(5, 198, NULL, 306, 'Issue Photo', 'img0990097.jpg', '312a80e1fa434073bf09cd22c9a70b2f.jpg', 'tickets/198/312a80e1fa434073bf09cd22c9a70b2f.jpg', 'image/jpeg', 383435, 'b45b65e63b5265365e981fbcfa110c0eade7ee933c8647eb6bc86c847c451d61', 1, '2026-08-30 01:51:16', NULL),
(6, 199, NULL, 505, 'Issue Photo', 'img034534.jpg', '61676d1f69ae426a90a1ed0745313692.jpg', 'tickets/199/61676d1f69ae426a90a1ed0745313692.jpg', 'image/jpeg', 284236, '47a07d13f9d8abc559adcd20125226b3042cebee179ccf4a1e963408a3c973f1', 1, '2026-08-30 10:13:45', NULL),
(7, 201, NULL, 498, 'Issue Photo', 'img89167326.jpg', 'b75d77038398482488206c7e55f726c4.jpg', 'tickets/201/b75d77038398482488206c7e55f726c4.jpg', 'image/jpeg', 286905, '72af21cc4dc7764bb84b91b738a05e4ed8aed8e7dd5f403528a5a7607cb32915', 1, '2026-08-30 16:34:15', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `ticket_feedback`
--

CREATE TABLE `ticket_feedback` (
  `feedback_id` bigint(20) UNSIGNED NOT NULL,
  `ticket_id` bigint(20) UNSIGNED NOT NULL,
  `resident_id` bigint(20) UNSIGNED NOT NULL,
  `resolution_confirmed` tinyint(1) NOT NULL DEFAULT 1,
  `rating` tinyint(3) UNSIGNED DEFAULT NULL,
  `comment` varchar(1000) DEFAULT NULL,
  `reopened_after_feedback` tinyint(1) NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ;

-- --------------------------------------------------------

--
-- Table structure for table `ticket_status_transitions`
--

CREATE TABLE `ticket_status_transitions` (
  `transition_id` bigint(20) UNSIGNED NOT NULL,
  `from_status` varchar(30) NOT NULL,
  `to_status` varchar(30) NOT NULL,
  `requires_note` tinyint(1) NOT NULL DEFAULT 0,
  `active` tinyint(1) NOT NULL DEFAULT 1,
  `description` varchar(255) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `ticket_status_transitions`
--

INSERT INTO `ticket_status_transitions` (`transition_id`, `from_status`, `to_status`, `requires_note`, `active`, `description`) VALUES
(1, 'Submitted', 'Analysing', 0, 1, 'AI analysis begins'),
(2, 'Submitted', 'Cancelled', 1, 1, 'Resident or admin cancels an invalid ticket'),
(3, 'Analysing', 'Awaiting Review', 0, 1, 'Normal workflow or manual review required'),
(4, 'Analysing', 'Auto Assigned', 0, 1, 'Emergency workflow selected a technician'),
(5, 'Analysing', 'Urgent Unassigned', 1, 1, 'Critical ticket has no suitable technician'),
(6, 'Analysing', 'Cancelled', 1, 1, 'Ticket cannot continue'),
(7, 'Awaiting Review', 'Assigned', 0, 1, 'Admin assigns a technician'),
(8, 'Awaiting Review', 'Auto Assigned', 0, 1, 'Emergency assignment is completed'),
(9, 'Awaiting Review', 'Urgent Unassigned', 1, 1, 'Urgent case has no available technician'),
(10, 'Awaiting Review', 'Cancelled', 1, 1, 'Admin cancels the ticket'),
(11, 'Urgent Unassigned', 'Assigned', 0, 1, 'Admin finds a technician'),
(12, 'Urgent Unassigned', 'Auto Assigned', 0, 1, 'Technician becomes available and system auto assigns'),
(13, 'Urgent Unassigned', 'Cancelled', 1, 1, 'Urgent ticket is cancelled with a reason'),
(14, 'Auto Assigned', 'Accepted', 0, 1, 'Technician accepts emergency assignment'),
(15, 'Auto Assigned', 'Assigned', 1, 1, 'Admin overrides or reassigns automatic assignment'),
(16, 'Auto Assigned', 'Urgent Unassigned', 1, 1, 'Automatic technician cannot accept and no replacement exists'),
(17, 'Auto Assigned', 'Cancelled', 1, 1, 'Emergency ticket cancelled with reason'),
(18, 'Assigned', 'Accepted', 0, 1, 'Technician accepts assignment'),
(19, 'Assigned', 'Awaiting Review', 1, 1, 'Technician declines and ticket returns to admin review'),
(20, 'Assigned', 'Cancelled', 1, 1, 'Assigned ticket cancelled'),
(21, 'Accepted', 'In Progress', 0, 1, 'Technician starts work'),
(22, 'Accepted', 'On Hold', 1, 1, 'Accepted job placed on hold'),
(23, 'Accepted', 'Cancelled', 1, 1, 'Accepted job cancelled'),
(24, 'In Progress', 'On Hold', 1, 1, 'Waiting for parts or access'),
(25, 'In Progress', 'Resolved', 1, 1, 'Repair work completed'),
(26, 'On Hold', 'In Progress', 0, 1, 'Work resumes'),
(27, 'On Hold', 'Resolved', 1, 1, 'Held work completed'),
(28, 'On Hold', 'Cancelled', 1, 1, 'Held job cancelled'),
(29, 'Resolved', 'Closed', 0, 1, 'Resident or admin confirms resolution'),
(30, 'Resolved', 'Reopened', 1, 1, 'Issue remains unresolved'),
(31, 'Closed', 'Reopened', 1, 1, 'Issue reoccurs'),
(32, 'Reopened', 'Analysing', 0, 1, 'Ticket re-enters AI analysis'),
(33, 'Reopened', 'Awaiting Review', 0, 1, 'Ticket returns to admin review'),
(34, 'Reopened', 'Assigned', 0, 1, 'Admin assigns a technician after reopening'),
(35, 'Reopened', 'Auto Assigned', 0, 1, 'Reopened emergency ticket is auto assigned');

-- --------------------------------------------------------

--
-- Table structure for table `ticket_updates`
--

CREATE TABLE `ticket_updates` (
  `update_id` bigint(20) UNSIGNED NOT NULL,
  `ticket_id` bigint(20) UNSIGNED NOT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `update_type` enum('System Event','Status Update','Repair Note','Admin Note','Resident Note','Completion Note','Reopen Note','Cancellation Note') NOT NULL DEFAULT 'System Event',
  `status_from` varchar(30) DEFAULT NULL,
  `status_to` varchar(30) DEFAULT NULL,
  `note` text DEFAULT NULL,
  `parts_used` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`parts_used`)),
  `resident_visible` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `ticket_updates`
--

INSERT INTO `ticket_updates` (`update_id`, `ticket_id`, `updated_by`, `update_type`, `status_from`, `status_to`, `note`, `parts_used`, `resident_visible`, `created_at`) VALUES
(491, 65, 297, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 14:05:00'),
(492, 66, 285, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 15:10:00'),
(493, 67, 277, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 08:15:00'),
(494, 68, 280, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 14:20:00'),
(495, 69, 291, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-21 13:10:00'),
(496, 70, 303, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 14:15:00'),
(497, 71, 306, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 15:20:00'),
(498, 72, 272, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 08:25:00'),
(499, 73, 299, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 14:35:00'),
(500, 74, 294, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-21 13:25:00'),
(501, 75, 308, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 14:25:00'),
(502, 76, 286, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 15:30:00'),
(503, 77, 281, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 08:35:00'),
(504, 78, 296, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 14:50:00'),
(505, 79, 274, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-21 13:40:00'),
(506, 80, 304, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 14:35:00'),
(507, 81, 279, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 15:40:00'),
(508, 82, 276, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 08:45:00'),
(509, 83, 301, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 15:05:00'),
(510, 84, 284, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-21 13:55:00'),
(511, 85, 273, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 14:45:00'),
(512, 86, 287, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 15:50:00'),
(513, 87, 302, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 08:55:00'),
(514, 88, 298, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 15:20:00'),
(515, 89, 293, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-21 14:10:00'),
(516, 90, 292, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-20 10:20:00'),
(517, 91, 290, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-20 11:15:00'),
(518, 92, 289, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-20 09:10:00'),
(522, 65, 297, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Carpentry, priority Low, risk 24.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 14:05:02'),
(523, 66, 285, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Gas, priority Emergency, risk 97.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 15:10:02'),
(524, 67, 277, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Plumbing, priority Medium, risk 38.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 08:15:02'),
(525, 68, 280, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Air Conditioning, priority Medium, risk 44.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 14:20:02'),
(526, 69, 291, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Electrical, priority High, risk 76.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-21 13:10:02'),
(527, 70, 303, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Pest Control, priority Low, risk 27.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 14:15:02'),
(528, 71, 306, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Lift, priority Emergency, risk 94.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 15:20:02'),
(529, 72, 272, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Security and Access, priority High, risk 63.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 08:25:02'),
(530, 73, 299, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Drainage, priority High, risk 72.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 14:35:02'),
(531, 74, 294, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Cleaning, priority Low, risk 29.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-21 13:25:02'),
(532, 75, 308, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Structural, priority High, risk 62.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 14:25:02'),
(533, 76, 286, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Fire and Safety, priority Emergency, risk 100.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 15:30:02'),
(534, 77, 281, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Carpentry, priority Low, risk 31.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 08:35:02'),
(535, 78, 296, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Plumbing, priority Medium, risk 48.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 14:50:02'),
(536, 79, 274, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Air Conditioning, priority Medium, risk 36.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-21 13:40:02'),
(537, 80, 304, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Other, priority Medium, risk 41.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 14:35:02'),
(538, 81, 279, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Electrical, priority Emergency, risk 96.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 15:40:02'),
(539, 82, 276, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Cleaning, priority Low, risk 21.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 08:45:02'),
(540, 83, 301, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Pest Control, priority Medium, risk 39.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 15:05:02'),
(541, 84, 284, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Structural, priority High, risk 68.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-21 13:55:02'),
(542, 85, 273, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Lift, priority High, risk 58.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 14:45:02'),
(543, 86, 287, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Gas, priority Emergency, risk 99.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 15:50:02'),
(544, 87, 302, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Electrical, priority High, risk 59.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 08:55:02'),
(545, 88, 298, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Security and Access, priority High, risk 57.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 15:20:02'),
(546, 89, 293, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Plumbing, priority Medium, risk 35.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-21 14:10:02'),
(547, 90, 292, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Other, priority Medium, risk 46.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-20 10:20:02'),
(548, 91, 290, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Fire and Safety, priority Emergency, risk 98.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-20 11:15:02'),
(549, 92, 289, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Drainage, priority High, risk 64.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-20 09:10:02'),
(553, 67, 335, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-23 08:45:00'),
(554, 68, 335, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 15:00:00'),
(555, 69, 335, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-21 13:25:00'),
(556, 72, 339, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-23 08:55:00'),
(557, 73, 339, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 15:10:00'),
(558, 74, 339, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-21 13:40:00'),
(559, 77, 336, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-23 09:05:00'),
(560, 78, 336, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 15:25:00'),
(561, 79, 336, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-21 13:55:00'),
(562, 82, 337, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-23 09:15:00'),
(563, 83, 337, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 15:40:00'),
(564, 84, 337, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-21 14:10:00'),
(565, 87, 338, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-23 09:25:00'),
(566, 88, 338, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 15:55:00'),
(567, 89, 338, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-21 14:25:00'),
(568, 92, 338, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-20 09:35:00'),
(584, 67, 335, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Chamara Perera.', NULL, 1, '2026-08-23 09:00:00'),
(585, 68, 335, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Dinesh Fernando.', NULL, 1, '2026-08-22 15:15:00'),
(586, 69, 335, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Nuwan Silva.', NULL, 1, '2026-08-21 13:35:00'),
(587, 72, 339, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Kanishka Samarasinghe.', NULL, 1, '2026-08-23 09:10:00'),
(588, 73, 339, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Udara Jayasinghe.', NULL, 1, '2026-08-22 15:25:00'),
(589, 74, 339, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Sameera Gunasekara.', NULL, 1, '2026-08-21 13:50:00'),
(590, 77, 336, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Lakmal Rathnayake.', NULL, 1, '2026-08-23 09:20:00'),
(591, 78, 336, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Buddhika Silva.', NULL, 1, '2026-08-22 15:40:00'),
(592, 79, 336, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Harsha Bandara.', NULL, 1, '2026-08-21 14:05:00'),
(593, 82, 337, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Yohan Gunawardena.', NULL, 1, '2026-08-23 09:30:00'),
(594, 83, 337, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Ashan Senanayake.', NULL, 1, '2026-08-22 15:55:00'),
(595, 84, 337, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Fairooz Ahamed.', NULL, 1, '2026-08-21 14:20:00'),
(596, 87, 338, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Heshan Perera.', NULL, 1, '2026-08-23 09:40:00'),
(597, 88, 338, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Udaya Samarasinghe.', NULL, 1, '2026-08-22 16:10:00'),
(598, 89, 338, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Ishan Silva.', NULL, 1, '2026-08-21 14:35:00'),
(599, 92, 338, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Lasantha Jayawardena.', NULL, 1, '2026-08-20 09:50:00'),
(615, 68, 361, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-22 15:40:00'),
(616, 69, 405, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-21 13:42:00'),
(617, 73, 409, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-22 15:45:00'),
(618, 74, 401, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-21 13:58:00'),
(619, 78, 354, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-22 16:00:00'),
(620, 79, 367, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-21 14:13:00'),
(621, 83, 352, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-22 16:15:00'),
(622, 84, 364, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-21 14:28:00'),
(623, 88, 410, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-22 16:30:00'),
(624, 89, 370, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-21 14:43:00'),
(630, 68, 361, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-23 09:10:00'),
(631, 69, 405, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-21 13:45:00'),
(632, 73, 409, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-23 09:25:00'),
(633, 74, 401, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-21 14:00:00'),
(634, 78, 354, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-23 09:40:00'),
(635, 79, 367, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-21 14:15:00'),
(636, 83, 352, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-23 09:55:00'),
(637, 84, 364, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-21 14:30:00'),
(638, 88, 410, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-23 10:10:00'),
(639, 89, 370, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-21 14:45:00'),
(645, 69, 405, 'Completion Note', 'In Progress', 'Resolved', 'Damaged socket replaced and wiring connections checked. Power was tested and restored safely.', NULL, 1, '2026-08-21 14:25:00'),
(646, 74, 401, 'Completion Note', 'In Progress', 'Resolved', 'Spill was cleaned, the floor was degreased and a temporary warning sign was used until the area dried.', NULL, 1, '2026-08-21 14:35:00'),
(647, 79, 367, 'Completion Note', 'In Progress', 'Resolved', 'Drain pipe blockage cleared, filter cleaned and AC drainage tested with no further leakage.', NULL, 1, '2026-08-21 15:00:00'),
(648, 84, 364, 'Completion Note', 'In Progress', 'Resolved', 'Loose plaster removed, area inspected and repaired. No deeper structural movement was identified during the inspection.', NULL, 1, '2026-08-21 15:20:00'),
(649, 89, 370, 'Completion Note', 'In Progress', 'Resolved', 'Cistern inlet valve adjusted and worn seal replaced. Water flow was tested and the leak stopped.', NULL, 1, '2026-08-21 15:30:00'),
(652, 96, 285, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 13:00:00'),
(653, 97, 277, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 13:17:00'),
(654, 98, 280, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 13:34:00'),
(655, 99, 291, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 13:51:00'),
(656, 100, 292, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 14:08:00'),
(657, 101, 288, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 14:25:00'),
(658, 102, 295, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 14:42:00'),
(659, 103, 303, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 14:59:00'),
(660, 104, 306, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 17:00:00'),
(661, 105, 272, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 17:17:00'),
(662, 106, 299, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 17:34:00'),
(663, 107, 294, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 17:51:00'),
(664, 108, 282, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 18:08:00'),
(665, 109, 278, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 18:25:00'),
(666, 110, 275, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 18:42:00'),
(667, 118, 283, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 09:42:00'),
(668, 111, 308, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-23 18:59:00'),
(669, 112, 286, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 08:00:00'),
(670, 113, 281, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 08:17:00'),
(671, 114, 296, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 08:34:00'),
(672, 115, 274, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 08:51:00'),
(673, 116, 305, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 09:08:00'),
(674, 117, 300, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 09:25:00'),
(675, 119, 304, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-22 09:59:00'),
(676, 120, 279, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-21 09:00:00'),
(677, 121, 276, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-21 09:17:00'),
(678, 122, 301, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-21 09:34:00'),
(679, 123, 284, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-21 09:51:00'),
(680, 124, 290, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-21 10:08:00'),
(681, 125, 309, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-21 10:25:00'),
(682, 126, 273, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-21 10:42:00'),
(683, 127, 287, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-18 10:29:00'),
(684, 128, 302, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-18 08:30:00'),
(685, 129, 298, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-18 08:47:00'),
(686, 130, 293, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-18 09:04:00'),
(687, 131, 289, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-18 09:21:00'),
(688, 132, 307, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-18 09:38:00'),
(715, 96, 285, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Plumbing, priority Medium, risk 46.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 13:00:02'),
(716, 97, 277, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Electrical, priority Low, risk 28.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 13:17:02'),
(717, 98, 280, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Air Conditioning, priority Medium, risk 42.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 13:34:02'),
(718, 99, 291, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Security and Access, priority Medium, risk 51.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 13:51:02'),
(719, 100, 292, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Drainage, priority Medium, risk 39.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 14:08:02'),
(720, 101, 288, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Carpentry, priority Low, risk 22.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 14:25:02'),
(721, 102, 295, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Pest Control, priority Low, risk 25.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 14:42:02'),
(722, 103, 303, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Lift, priority Medium, risk 48.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-23 14:59:02'),
(723, 104, 306, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Fire and Safety, priority Emergency, risk 96.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 17:00:02'),
(724, 105, 272, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Gas, priority Emergency, risk 98.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 17:17:02'),
(725, 106, 299, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Electrical, priority Emergency, risk 99.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 17:34:02'),
(726, 107, 294, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Structural, priority Emergency, risk 93.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 17:51:02'),
(727, 108, 282, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Plumbing, priority Emergency, risk 95.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 18:08:02'),
(728, 109, 278, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Air Conditioning, priority Emergency, risk 94.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 18:25:02'),
(729, 110, 275, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Security and Access, priority Emergency, risk 91.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 18:42:02'),
(730, 118, 283, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Carpentry, priority Low, risk 29.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 09:42:02'),
(731, 111, 308, 'System Event', 'Analysing', 'Urgent Unassigned', 'AI analysis completed. Category Cleaning, priority Emergency, risk 89.00/100. Emergency assignment could not be completed at that time, so the ticket remained urgently unassigned for admin attention.', NULL, 1, '2026-08-23 18:59:02'),
(732, 112, 286, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Lift, priority High, risk 72.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 08:00:02'),
(733, 113, 281, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Drainage, priority High, risk 78.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 08:17:02'),
(734, 114, 296, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Fire and Safety, priority High, risk 74.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 08:34:02'),
(735, 115, 274, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Electrical, priority High, risk 68.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 08:51:02'),
(736, 116, 305, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Pest Control, priority Medium, risk 54.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 09:08:02'),
(737, 117, 300, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Other, priority Medium, risk 43.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 09:25:02'),
(738, 119, 304, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Plumbing, priority Medium, risk 38.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-22 09:59:02'),
(739, 120, 279, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Electrical, priority Medium, risk 41.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-21 09:00:02'),
(740, 121, 276, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Security and Access, priority Medium, risk 37.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-21 09:17:02'),
(741, 122, 301, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Air Conditioning, priority Medium, risk 45.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-21 09:34:02'),
(742, 123, 284, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Structural, priority High, risk 63.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-21 09:51:02'),
(743, 124, 290, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Cleaning, priority Medium, risk 35.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-21 10:08:02'),
(744, 125, 309, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Drainage, priority Medium, risk 49.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-21 10:25:02'),
(745, 126, 273, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Lift, priority High, risk 70.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-21 10:42:02'),
(746, 127, 287, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Gas, priority High, risk 66.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-18 10:29:02'),
(747, 128, 302, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Fire and Safety, priority High, risk 64.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-18 08:30:02'),
(748, 129, 298, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Carpentry, priority Low, risk 26.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-18 08:47:02'),
(749, 130, 293, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Plumbing, priority Medium, risk 44.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-18 09:04:02'),
(750, 131, 289, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Pest Control, priority Medium, risk 52.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-18 09:21:02'),
(751, 132, 307, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category Security and Access, priority Medium, risk 47.00/100. Ticket moved to the apartment admin review queue.', NULL, 1, '2026-08-18 09:38:02'),
(778, 118, 336, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 10:06:00'),
(779, 112, 336, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 08:24:00'),
(780, 113, 336, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 08:41:00'),
(781, 114, 336, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 08:58:00'),
(782, 115, 336, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 09:15:00'),
(783, 116, 336, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 09:32:00'),
(784, 117, 336, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 09:49:00'),
(785, 119, 337, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-22 10:23:00'),
(786, 120, 337, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-21 09:24:00'),
(787, 121, 337, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-21 09:41:00'),
(788, 122, 337, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-21 09:58:00'),
(789, 123, 337, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-21 10:15:00'),
(790, 124, 337, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-21 10:32:00'),
(791, 125, 337, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-21 10:49:00'),
(792, 126, 338, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-21 11:06:00'),
(793, 127, 338, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-18 10:49:00'),
(794, 128, 338, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-18 08:50:00'),
(795, 129, 338, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-18 09:07:00'),
(796, 130, 338, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-18 09:24:00'),
(797, 131, 338, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-18 09:41:00'),
(798, 132, 338, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the AI category, priority and risk result and approved the ticket for technician assignment.', NULL, 1, '2026-08-18 09:58:00'),
(809, 118, 336, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Lakmal Rathnayake.', NULL, 1, '2026-08-22 10:20:00'),
(810, 112, 336, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Chamil Fernando.', NULL, 1, '2026-08-22 08:38:00'),
(811, 113, 336, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Indika Jayawardena.', NULL, 1, '2026-08-22 08:55:00'),
(812, 114, 336, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Nalaka Herath.', NULL, 1, '2026-08-22 09:12:00'),
(813, 115, 336, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Amila Perera.', NULL, 1, '2026-08-22 09:29:00'),
(814, 116, 336, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Kelum Senanayake.', NULL, 1, '2026-08-22 09:46:00'),
(815, 117, 336, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Milan Peiris.', NULL, 1, '2026-08-22 10:03:00'),
(816, 119, 337, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Thilak Silva.', NULL, 1, '2026-08-22 10:37:00'),
(817, 120, 337, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Sampath Perera.', NULL, 1, '2026-08-21 09:38:00'),
(818, 121, 337, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Gihan Samarasinghe.', NULL, 1, '2026-08-21 09:55:00'),
(819, 122, 337, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Vajira Bandara.', NULL, 1, '2026-08-21 10:12:00'),
(820, 123, 337, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Fairooz Ahamed.', NULL, 1, '2026-08-21 10:29:00'),
(821, 124, 337, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Yohan Gunawardena.', NULL, 1, '2026-08-21 10:46:00'),
(822, 125, 337, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Wasantha Jayawardena.', NULL, 1, '2026-08-21 11:03:00'),
(823, 126, 338, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Jayantha Fernando.', NULL, 1, '2026-08-21 11:20:00'),
(824, 127, 338, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Sajith Dissanayake.', NULL, 1, '2026-08-18 11:01:00'),
(825, 128, 338, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Ravimal Herath.', NULL, 1, '2026-08-18 09:02:00'),
(826, 129, 338, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Osanda Rathnayake.', NULL, 1, '2026-08-18 09:19:00'),
(827, 130, 338, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Ishan Silva.', NULL, 1, '2026-08-18 09:36:00'),
(828, 131, 338, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Naveen Senanayake.', NULL, 1, '2026-08-18 09:53:00'),
(829, 132, 338, 'System Event', 'Awaiting Review', 'Assigned', 'Apartment admin assigned the ticket to Udaya Samarasinghe.', NULL, 1, '2026-08-18 10:10:00'),
(840, 120, 402, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-21 09:47:00'),
(841, 121, 366, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-21 10:04:00'),
(842, 122, 412, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-21 10:21:00'),
(843, 123, 364, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-21 10:38:00'),
(844, 124, 414, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-21 10:55:00'),
(845, 125, 413, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-21 11:12:00'),
(846, 126, 373, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-21 11:29:00'),
(847, 127, 400, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-18 11:12:00'),
(848, 128, 395, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-18 09:13:00'),
(849, 129, 389, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-18 09:30:00'),
(850, 130, 370, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-18 09:47:00'),
(851, 131, 388, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-18 10:04:00'),
(852, 132, 410, 'Status Update', 'Assigned', 'Accepted', 'Technician accepted the assigned maintenance job.', NULL, 1, '2026-08-18 10:21:00'),
(855, 120, 402, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-21 09:59:00'),
(856, 121, 366, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-21 10:16:00'),
(857, 122, 412, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-21 10:33:00'),
(858, 123, 364, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-21 10:50:00'),
(859, 124, 414, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-21 11:07:00'),
(860, 125, 413, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-21 11:24:00'),
(861, 126, 373, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-21 11:41:00'),
(862, 127, 400, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-18 11:24:00'),
(863, 128, 395, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-18 09:25:00'),
(864, 129, 389, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-18 09:42:00'),
(865, 130, 370, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-18 09:59:00'),
(866, 131, 388, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-18 10:16:00'),
(867, 132, 410, 'Status Update', 'Accepted', 'In Progress', 'Technician started work on the maintenance job.', NULL, 1, '2026-08-18 10:33:00'),
(870, 127, 400, 'Completion Note', 'In Progress', 'Resolved', 'Technician tightened the regulator connection, replaced the worn sealing washer and completed a leak test with no leak detected.', NULL, 1, '2026-08-18 12:44:00'),
(871, 128, 395, 'Completion Note', 'In Progress', 'Resolved', 'Emergency light battery and lamp module were replaced. The unit passed the power failure test.', NULL, 1, '2026-08-18 10:15:00'),
(872, 129, 389, 'Completion Note', 'In Progress', 'Resolved', 'Door hinges were aligned and tightened, and the lower edge was adjusted so the door opens and closes without scraping.', NULL, 1, '2026-08-18 10:47:00'),
(873, 130, 370, 'Completion Note', 'In Progress', 'Resolved', 'The damaged inlet hose washer was replaced, the coupling was tightened and the water connection was tested without leakage.', NULL, 1, '2026-08-18 11:19:00'),
(874, 131, 388, 'Completion Note', 'In Progress', 'Resolved', 'Affected timber was treated for termites and the surrounding wooden frame was inspected. A follow-up inspection was scheduled.', NULL, 1, '2026-08-18 11:06:00'),
(875, 132, 410, 'Completion Note', 'In Progress', 'Resolved', 'The card reader was cleaned and reconfigured. Multiple resident access cards were tested successfully after the repair.', NULL, 1, '2026-08-18 11:38:00'),
(876, 133, 300, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the live database. Local multilingual AI analysis has started.', NULL, 1, '2026-08-26 18:44:33');
INSERT INTO `ticket_updates` (`update_id`, `ticket_id`, `updated_by`, `update_type`, `status_from`, `status_to`, `note`, `parts_used`, `resident_visible`, `created_at`) VALUES
(877, 133, 300, '', 'Analysing', 'Awaiting Review', 'Local AI analysis completed. Category Plumbing, priority High, risk 53.2/100 (Medium).', NULL, 1, '2026-08-26 18:44:35'),
(878, 133, 336, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the ticket classification and priority.', NULL, 1, '2026-08-26 18:57:25'),
(879, 133, 336, 'System Event', 'Awaiting Review', 'Assigned', 'Assigned to Indika Jayawardena by apartment admin.', NULL, 1, '2026-08-26 18:57:50'),
(880, 133, 369, 'Status Update', 'Assigned', 'Accepted', 'Job status changed to Accepted.', NULL, 1, '2026-08-26 18:59:04'),
(881, 133, 369, 'Status Update', 'Accepted', 'In Progress', 'Job status changed to In Progress.', NULL, 1, '2026-08-26 19:00:09'),
(882, 133, 369, 'Completion Note', 'In Progress', 'Resolved', 'Completed', NULL, 1, '2026-08-26 19:02:08'),
(883, 134, 277, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 08:15:00'),
(884, 135, 280, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 09:28:00'),
(885, 136, 285, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 10:41:00'),
(886, 137, 288, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 11:54:00'),
(887, 138, 291, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 13:07:00'),
(888, 139, 292, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 14:20:00'),
(889, 140, 295, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 15:33:00'),
(890, 141, 297, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 16:46:00'),
(891, 142, 484, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 17:59:00'),
(892, 143, 485, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 19:12:00'),
(893, 144, 486, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 20:25:00'),
(894, 145, 487, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 21:38:00'),
(895, 146, 488, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-24 22:51:00'),
(896, 147, 272, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 00:04:00'),
(897, 148, 275, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 01:17:00'),
(898, 149, 278, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 02:30:00'),
(899, 150, 282, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 03:43:00'),
(900, 151, 294, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 04:56:00'),
(901, 152, 299, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 06:09:00'),
(902, 153, 303, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 07:22:00'),
(903, 154, 306, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 08:35:00'),
(904, 155, 489, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 09:48:00'),
(905, 156, 490, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 11:01:00'),
(906, 157, 491, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 12:14:00'),
(907, 158, 492, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 13:27:00'),
(908, 159, 274, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 14:40:00'),
(909, 160, 281, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 15:53:00'),
(910, 161, 283, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 17:06:00'),
(911, 162, 286, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 18:19:00'),
(912, 163, 296, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 19:32:00'),
(913, 164, 300, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 20:45:00'),
(914, 165, 305, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 21:58:00'),
(915, 166, 308, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-25 23:11:00'),
(916, 167, 493, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 00:24:00'),
(917, 168, 494, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 01:37:00'),
(918, 169, 495, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 02:50:00'),
(919, 170, 496, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 04:03:00'),
(920, 171, 497, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 05:16:00'),
(921, 172, 276, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 06:29:00'),
(922, 173, 279, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 07:42:00'),
(923, 174, 284, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 08:55:00'),
(924, 175, 290, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 10:08:00'),
(925, 176, 301, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 11:21:00'),
(926, 177, 304, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 12:34:00'),
(927, 178, 309, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 13:47:00'),
(928, 179, 498, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 15:00:00'),
(929, 180, 499, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 16:13:00'),
(930, 181, 500, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 17:26:00'),
(931, 182, 501, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 18:39:00'),
(932, 183, 273, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 19:52:00'),
(933, 184, 287, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 21:05:00'),
(934, 185, 289, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 22:18:00'),
(935, 186, 293, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-26 23:31:00'),
(936, 187, 298, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-27 00:44:00'),
(937, 188, 302, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-27 01:57:00'),
(938, 189, 307, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-27 03:10:00'),
(939, 190, 502, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-27 04:23:00'),
(940, 191, 503, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-27 05:36:00'),
(941, 192, 504, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-27 06:49:00'),
(942, 193, 505, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the HelaFixIt AI database. Local multilingual AI analysis started.', NULL, 1, '2026-08-27 08:02:00'),
(946, 134, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Lift with high priority and risk score 64.', NULL, 1, '2026-08-24 08:15:02'),
(947, 135, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 134 was detected with similarity 0.92. Duplicate review is required.', NULL, 1, '2026-08-24 09:28:02'),
(948, 136, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Plumbing with medium priority and risk score 48.', NULL, 1, '2026-08-24 10:41:02'),
(949, 137, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 136 was detected with similarity 0.94. Duplicate review is required.', NULL, 1, '2026-08-24 11:54:02'),
(950, 138, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Electrical with high priority and risk score 68.', NULL, 1, '2026-08-24 13:07:02'),
(951, 139, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 138 was detected with similarity 0.91. Duplicate review is required.', NULL, 1, '2026-08-24 14:20:02'),
(952, 140, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Carpentry with low priority and risk score 25.', NULL, 1, '2026-08-24 15:33:02'),
(953, 141, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Security and Access with high priority and risk score 65.', NULL, 1, '2026-08-24 16:46:02'),
(954, 142, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Plumbing with medium priority and risk score 48.', NULL, 1, '2026-08-24 17:59:02'),
(955, 143, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Drainage with high priority and risk score 62.', NULL, 1, '2026-08-24 19:12:02'),
(956, 144, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Pest Control with low priority and risk score 28.', NULL, 1, '2026-08-24 20:25:02'),
(957, 145, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Other with medium priority and risk score 38.', NULL, 1, '2026-08-24 21:38:02'),
(958, 146, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Security and Access with high priority and risk score 65.', NULL, 1, '2026-08-24 22:51:02'),
(959, 147, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Lift with high priority and risk score 64.', NULL, 1, '2026-08-25 00:04:02'),
(960, 148, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 147 was detected with similarity 0.95. Duplicate review is required.', NULL, 1, '2026-08-25 01:17:02'),
(961, 149, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Plumbing with medium priority and risk score 48.', NULL, 1, '2026-08-25 02:30:02'),
(962, 150, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 149 was detected with similarity 0.92. Duplicate review is required.', NULL, 1, '2026-08-25 03:43:02'),
(963, 151, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Electrical with high priority and risk score 68.', NULL, 1, '2026-08-25 04:56:02'),
(964, 152, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 151 was detected with similarity 0.94. Duplicate review is required.', NULL, 1, '2026-08-25 06:09:02'),
(965, 153, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Pest Control with low priority and risk score 28.', NULL, 1, '2026-08-25 07:22:02'),
(966, 154, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Security and Access with high priority and risk score 65.', NULL, 1, '2026-08-25 08:35:02'),
(967, 155, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Structural with high priority and risk score 72.', NULL, 1, '2026-08-25 09:48:02'),
(968, 156, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Lift with high priority and risk score 64.', NULL, 1, '2026-08-25 11:01:02'),
(969, 157, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Plumbing with medium priority and risk score 48.', NULL, 1, '2026-08-25 12:14:02'),
(970, 158, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Drainage with high priority and risk score 62.', NULL, 1, '2026-08-25 13:27:02'),
(971, 159, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Lift with high priority and risk score 64.', NULL, 1, '2026-08-25 14:40:02'),
(972, 160, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 159 was detected with similarity 0.92. Duplicate review is required.', NULL, 1, '2026-08-25 15:53:02'),
(973, 161, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Plumbing with medium priority and risk score 48.', NULL, 1, '2026-08-25 17:06:02'),
(974, 162, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 161 was detected with similarity 0.94. Duplicate review is required.', NULL, 1, '2026-08-25 18:19:02'),
(975, 163, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Electrical with high priority and risk score 68.', NULL, 1, '2026-08-25 19:32:02'),
(976, 164, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 163 was detected with similarity 0.91. Duplicate review is required.', NULL, 1, '2026-08-25 20:45:02'),
(977, 165, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Structural with high priority and risk score 72.', NULL, 1, '2026-08-25 21:58:02'),
(978, 166, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Plumbing with medium priority and risk score 48.', NULL, 1, '2026-08-25 23:11:02'),
(979, 167, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Air Conditioning with medium priority and risk score 42.', NULL, 1, '2026-08-26 00:24:02'),
(980, 168, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Cleaning with low priority and risk score 22.', NULL, 1, '2026-08-26 01:37:02'),
(981, 169, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Carpentry with low priority and risk score 25.', NULL, 1, '2026-08-26 02:50:02'),
(982, 170, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Structural with high priority and risk score 72.', NULL, 1, '2026-08-26 04:03:02'),
(983, 171, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Lift with high priority and risk score 64.', NULL, 1, '2026-08-26 05:16:02'),
(984, 172, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Lift with high priority and risk score 64.', NULL, 1, '2026-08-26 06:29:02'),
(985, 173, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 172 was detected with similarity 0.95. Duplicate review is required.', NULL, 1, '2026-08-26 07:42:02'),
(986, 174, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Plumbing with medium priority and risk score 48.', NULL, 1, '2026-08-26 08:55:02'),
(987, 175, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 174 was detected with similarity 0.92. Duplicate review is required.', NULL, 1, '2026-08-26 10:08:02'),
(988, 176, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Electrical with high priority and risk score 68.', NULL, 1, '2026-08-26 11:21:02'),
(989, 177, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 176 was detected with similarity 0.94. Duplicate review is required.', NULL, 1, '2026-08-26 12:34:02'),
(990, 178, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Drainage with high priority and risk score 62.', NULL, 1, '2026-08-26 13:47:02'),
(991, 179, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Structural with high priority and risk score 72.', NULL, 1, '2026-08-26 15:00:02'),
(992, 180, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Lift with high priority and risk score 64.', NULL, 1, '2026-08-26 16:13:02'),
(993, 181, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Plumbing with medium priority and risk score 48.', NULL, 1, '2026-08-26 17:26:02'),
(994, 182, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Drainage with high priority and risk score 62.', NULL, 1, '2026-08-26 18:39:02'),
(995, 183, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Lift with high priority and risk score 64.', NULL, 1, '2026-08-26 19:52:02'),
(996, 184, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 183 was detected with similarity 0.91. Duplicate review is required.', NULL, 1, '2026-08-26 21:05:02'),
(997, 185, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Plumbing with medium priority and risk score 48.', NULL, 1, '2026-08-26 22:18:02'),
(998, 186, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 185 was detected with similarity 0.93. Duplicate review is required.', NULL, 1, '2026-08-26 23:31:02'),
(999, 187, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Electrical with high priority and risk score 68.', NULL, 1, '2026-08-27 00:44:02'),
(1000, 188, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Similar active ticket 187 was detected with similarity 0.95. Duplicate review is required.', NULL, 1, '2026-08-27 01:57:02'),
(1001, 189, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Plumbing with medium priority and risk score 48.', NULL, 1, '2026-08-27 03:10:02'),
(1002, 190, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Plumbing with medium priority and risk score 48.', NULL, 1, '2026-08-27 04:23:02'),
(1003, 191, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Drainage with high priority and risk score 62.', NULL, 1, '2026-08-27 05:36:02'),
(1004, 192, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Pest Control with low priority and risk score 28.', NULL, 1, '2026-08-27 06:49:02'),
(1005, 193, NULL, 'System Event', 'Analysing', 'Awaiting Review', 'AI analysis completed. Category predicted as Other with medium priority and risk score 38.', NULL, 1, '2026-08-27 08:02:02'),
(1006, 194, 277, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the live database. Local multilingual AI analysis has started.', NULL, 1, '2026-08-29 10:31:11'),
(1007, 194, 277, '', 'Analysing', 'Awaiting Review', 'Local AI analysis completed. Category Plumbing, priority High, risk 54.7/100 (Medium).', NULL, 1, '2026-08-29 10:31:14'),
(1008, 194, 335, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the ticket classification and priority.', NULL, 1, '2026-08-29 10:32:42'),
(1009, 194, 335, 'System Event', 'Awaiting Review', 'Assigned', 'Assigned to Isuru Madushan by apartment admin.', NULL, 1, '2026-08-29 10:32:58'),
(1010, 194, 371, 'Status Update', 'Assigned', 'Accepted', 'Job status changed to Accepted.', NULL, 1, '2026-08-29 10:34:13'),
(1011, 194, 371, 'Status Update', 'Accepted', 'In Progress', 'Job status changed to In Progress.', NULL, 1, '2026-08-29 10:36:11'),
(1012, 195, 301, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the live database. Local multilingual AI analysis has started.', NULL, 1, '2026-08-29 11:08:29'),
(1013, 195, 301, '', 'Analysing', 'Auto Assigned', 'Local AI analysis completed. Category Electrical, priority Emergency, risk 100.0/100 (Critical). Emergency auto assignment selected Sampath Perera.', NULL, 1, '2026-08-29 11:08:31'),
(1014, 193, 342, 'System Event', 'Awaiting Review', 'Assigned', 'Assigned to Pubudu Peiris by apartment admin.', NULL, 1, '2026-08-29 13:45:04'),
(1015, 193, 393, 'Status Update', 'Assigned', 'Accepted', 'Job status changed to Accepted.', NULL, 1, '2026-08-29 13:46:03'),
(1016, 196, 277, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the live database. Local multilingual AI analysis has started.', NULL, 1, '2026-08-30 00:27:49'),
(1017, 196, 277, 'System Event', 'Analysing', 'Awaiting Review', 'Local AI analysis completed. Category Lift, priority High, risk 62.7/100 (High).', NULL, 1, '2026-08-30 00:27:53'),
(1018, 196, 335, 'System Event', 'Awaiting Review', 'Awaiting Review', 'Local AI analysis completed. Category Lift, priority High, risk 62.7/100 (High).', NULL, 1, '2026-08-30 00:28:43'),
(1019, 196, 335, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the ticket classification and priority.', NULL, 1, '2026-08-30 00:28:53'),
(1020, 196, 335, 'System Event', 'Awaiting Review', 'Assigned', 'Assigned to Supun Jayasinghe by apartment admin.', NULL, 1, '2026-08-30 00:29:12'),
(1021, 197, 501, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the live database. Local multilingual AI analysis has started.', NULL, 1, '2026-08-30 00:37:08'),
(1022, 197, 501, 'System Event', 'Analysing', 'Auto Assigned', 'Local AI analysis completed. Category Electrical, priority Emergency, risk 100.0/100 (Critical). Emergency auto assignment selected Sampath Perera.', NULL, 1, '2026-08-30 00:37:09'),
(1023, 198, 306, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the live database. Local multilingual AI analysis has started.', NULL, 1, '2026-08-30 01:51:16'),
(1024, 198, 306, 'System Event', 'Analysing', 'Auto Assigned', 'Local AI analysis completed. Category Electrical, priority Emergency, risk 100.0/100 (Critical). Emergency auto assignment selected Gayan Perera.', NULL, 1, '2026-08-30 01:51:18'),
(1025, 198, 365, 'Status Update', 'Auto Assigned', 'Accepted', 'Job status changed to Accepted.', NULL, 1, '2026-08-30 01:54:18'),
(1026, 198, 365, 'Status Update', 'Accepted', 'In Progress', 'Job status changed to In Progress.', NULL, 1, '2026-08-30 01:54:46'),
(1027, 199, 505, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the live database. Local multilingual AI analysis has started.', NULL, 1, '2026-08-30 10:13:44'),
(1028, 199, 505, 'System Event', 'Analysing', 'Awaiting Review', 'Local AI analysis completed. Category Security and Access, priority High, risk 76.0/100 (High).', NULL, 1, '2026-08-30 10:13:47'),
(1029, 199, 338, 'Admin Note', 'Awaiting Review', 'Awaiting Review', 'Apartment admin reviewed the ticket classification and priority.', NULL, 1, '2026-08-30 10:15:19'),
(1030, 199, 338, 'System Event', 'Awaiting Review', 'Assigned', 'Assigned to Udaya Samarasinghe by apartment admin.', NULL, 1, '2026-08-30 10:15:33'),
(1031, 200, 307, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the live database. Local multilingual AI analysis has started.', NULL, 1, '2026-08-30 10:22:03'),
(1032, 200, 307, 'System Event', 'Analysing', 'Auto Assigned', 'Local AI analysis completed. Category Fire and Safety, priority Emergency, risk 100.0/100 (Critical). Emergency auto assignment selected Ravimal Herath.', NULL, 1, '2026-08-30 10:22:04'),
(1033, 201, 498, 'System Event', 'Submitted', 'Analysing', 'Ticket stored in the live database. Local multilingual AI analysis has started.', NULL, 1, '2026-08-30 16:34:15'),
(1034, 201, 498, 'System Event', 'Analysing', 'Auto Assigned', 'Local AI analysis completed. Category Electrical, priority Emergency, risk 100.0/100 (Critical). Emergency auto assignment selected Sampath Perera.', NULL, 1, '2026-08-30 16:34:18'),
(1035, 201, 402, 'Status Update', 'Auto Assigned', 'Accepted', 'Job status changed to Accepted.', NULL, 1, '2026-08-30 16:35:23');

-- --------------------------------------------------------

--
-- Table structure for table `units`
--

CREATE TABLE `units` (
  `unit_id` bigint(20) UNSIGNED NOT NULL,
  `floor_id` bigint(20) UNSIGNED NOT NULL,
  `unit_number` varchar(40) NOT NULL,
  `unit_type` enum('Apartment','Common Facility','Staff','Other') NOT NULL DEFAULT 'Apartment',
  `status` enum('Active','Inactive') NOT NULL DEFAULT 'Active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `units`
--

INSERT INTO `units` (`unit_id`, `floor_id`, `unit_number`, `unit_type`, `status`, `created_at`, `updated_at`) VALUES
(1, 2, 'A-503', 'Apartment', 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(2, 4, 'B-305', 'Apartment', 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(3, 7, 'C-806', 'Apartment', 'Active', '2026-08-15 13:50:19', '2026-08-15 13:50:19'),
(4, 4, 'B-303', 'Apartment', 'Active', '2026-08-17 13:30:00', '2026-08-17 13:30:00'),
(5, 62, 'E-101', 'Apartment', 'Active', '2026-08-17 14:33:00', '2026-08-17 14:33:00'),
(6, 20, 'C-505', 'Apartment', 'Active', '2026-08-17 14:00:00', '2026-08-17 14:00:00'),
(7, 28, 'B-808', 'Apartment', 'Active', '2026-08-17 13:45:00', '2026-08-17 13:45:00'),
(8, 54, 'D-303', 'Apartment', 'Active', '2026-08-17 14:18:00', '2026-08-17 14:18:00'),
(9, 14, 'A-303', 'Apartment', 'Active', '2026-08-17 13:06:00', '2026-08-17 13:06:00'),
(10, 25, 'B-707', 'Apartment', 'Active', '2026-08-17 13:42:00', '2026-08-17 13:42:00'),
(11, 53, 'D-202', 'Apartment', 'Active', '2026-08-17 14:15:00', '2026-08-17 14:15:00'),
(12, 16, 'A-404', 'Apartment', 'Active', '2026-08-17 13:09:00', '2026-08-17 13:09:00'),
(13, 15, 'C-303', 'Apartment', 'Active', '2026-08-17 13:54:00', '2026-08-17 13:54:00'),
(14, 22, 'B-606', 'Apartment', 'Active', '2026-08-17 13:39:00', '2026-08-17 13:39:00'),
(15, 7, 'C-808', 'Apartment', 'Active', '2026-08-17 14:09:00', '2026-08-17 14:09:00'),
(16, 56, 'D-505', 'Apartment', 'Active', '2026-08-17 14:24:00', '2026-08-17 14:24:00'),
(17, 11, 'A-202', 'Apartment', 'Active', '2026-08-17 13:03:00', '2026-08-17 13:03:00'),
(18, 13, 'C-202', 'Apartment', 'Active', '2026-08-17 13:51:00', '2026-08-17 13:51:00'),
(19, 63, 'E-202', 'Apartment', 'Active', '2026-08-17 14:36:00', '2026-08-17 14:36:00'),
(20, 24, 'A-707', 'Apartment', 'Active', '2026-08-17 13:18:00', '2026-08-17 13:18:00'),
(21, 67, 'E-606', 'Apartment', 'Active', '2026-08-17 14:48:00', '2026-08-17 14:48:00'),
(22, 57, 'D-606', 'Apartment', 'Active', '2026-08-17 14:27:00', '2026-08-17 14:27:00'),
(23, 2, 'A-505', 'Apartment', 'Active', '2026-08-17 13:12:00', '2026-08-17 13:12:00'),
(24, 21, 'A-606', 'Apartment', 'Active', '2026-08-17 13:15:00', '2026-08-17 13:15:00'),
(25, 66, 'E-505', 'Apartment', 'Active', '2026-08-17 14:45:00', '2026-08-17 14:45:00'),
(26, 19, 'B-505', 'Apartment', 'Active', '2026-08-17 13:36:00', '2026-08-17 13:36:00'),
(27, 27, 'A-808', 'Apartment', 'Active', '2026-08-17 13:21:00', '2026-08-17 13:21:00'),
(28, 18, 'C-404', 'Apartment', 'Active', '2026-08-17 13:57:00', '2026-08-17 13:57:00'),
(29, 8, 'A-101', 'Apartment', 'Active', '2026-08-17 13:00:00', '2026-08-17 13:00:00'),
(30, 65, 'E-404', 'Apartment', 'Active', '2026-08-17 14:42:00', '2026-08-17 14:42:00'),
(31, 17, 'B-404', 'Apartment', 'Active', '2026-08-17 13:33:00', '2026-08-17 13:33:00'),
(32, 26, 'C-707', 'Apartment', 'Active', '2026-08-17 14:06:00', '2026-08-17 14:06:00'),
(33, 55, 'D-404', 'Apartment', 'Active', '2026-08-17 14:21:00', '2026-08-17 14:21:00'),
(34, 64, 'E-303', 'Apartment', 'Active', '2026-08-17 14:39:00', '2026-08-17 14:39:00'),
(35, 9, 'B-101', 'Apartment', 'Active', '2026-08-17 13:24:00', '2026-08-17 13:24:00'),
(36, 52, 'D-101', 'Apartment', 'Active', '2026-08-17 14:12:00', '2026-08-17 14:12:00'),
(37, 23, 'C-606', 'Apartment', 'Active', '2026-08-17 14:03:00', '2026-08-17 14:03:00'),
(38, 12, 'B-202', 'Apartment', 'Active', '2026-08-17 13:27:00', '2026-08-17 13:27:00'),
(39, 68, 'E-707', 'Apartment', 'Active', '2026-08-17 14:51:00', '2026-08-17 14:51:00'),
(40, 10, 'C-101', 'Apartment', 'Active', '2026-08-17 13:48:00', '2026-08-17 13:48:00'),
(41, 58, 'D-707', 'Apartment', 'Active', '2026-08-17 14:30:00', '2026-08-17 14:30:00'),
(68, 29, 'A-903', 'Apartment', 'Active', '2026-08-21 09:00:00', '2026-08-21 09:00:00'),
(69, 32, 'A-1004', 'Apartment', 'Active', '2026-08-21 09:37:00', '2026-08-21 09:37:00'),
(70, 38, 'A-1202', 'Apartment', 'Active', '2026-08-21 10:14:00', '2026-08-21 10:14:00'),
(71, 44, 'A-1405', 'Apartment', 'Active', '2026-08-21 10:51:00', '2026-08-21 10:51:00'),
(72, 47, 'A-1506', 'Apartment', 'Active', '2026-08-21 11:28:00', '2026-08-21 11:28:00'),
(73, 30, 'B-902', 'Apartment', 'Active', '2026-08-21 12:05:00', '2026-08-21 12:05:00'),
(74, 33, 'B-1003', 'Apartment', 'Active', '2026-08-21 12:42:00', '2026-08-21 12:42:00'),
(75, 39, 'B-1204', 'Apartment', 'Active', '2026-08-21 13:19:00', '2026-08-21 13:19:00'),
(76, 45, 'B-1402', 'Apartment', 'Active', '2026-08-21 13:56:00', '2026-08-21 13:56:00'),
(77, 31, 'C-903', 'Apartment', 'Active', '2026-08-21 14:33:00', '2026-08-21 14:33:00'),
(78, 34, 'C-1002', 'Apartment', 'Active', '2026-08-21 15:10:00', '2026-08-21 15:10:00'),
(79, 40, 'C-1203', 'Apartment', 'Active', '2026-08-21 15:47:00', '2026-08-21 15:47:00'),
(80, 46, 'C-1404', 'Apartment', 'Active', '2026-08-21 16:24:00', '2026-08-21 16:24:00'),
(81, 51, 'C-1602', 'Apartment', 'Active', '2026-08-21 17:01:00', '2026-08-21 17:01:00'),
(82, 59, 'D-802', 'Apartment', 'Active', '2026-08-21 17:38:00', '2026-08-21 17:38:00'),
(83, 60, 'D-903', 'Apartment', 'Active', '2026-08-21 18:15:00', '2026-08-21 18:15:00'),
(84, 61, 'D-1004', 'Apartment', 'Active', '2026-08-21 18:52:00', '2026-08-21 18:52:00'),
(85, 57, 'D-602', 'Apartment', 'Active', '2026-08-21 19:29:00', '2026-08-21 19:29:00'),
(86, 69, 'E-802', 'Apartment', 'Active', '2026-08-21 20:06:00', '2026-08-21 20:06:00'),
(87, 70, 'E-903', 'Apartment', 'Active', '2026-08-21 20:43:00', '2026-08-21 20:43:00'),
(88, 71, 'E-1004', 'Apartment', 'Active', '2026-08-21 21:20:00', '2026-08-21 21:20:00'),
(89, 72, 'E-1102', 'Apartment', 'Active', '2026-08-21 21:57:00', '2026-08-21 21:57:00');

-- --------------------------------------------------------

--
-- Table structure for table `users`
--

CREATE TABLE `users` (
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `role_id` bigint(20) UNSIGNED NOT NULL,
  `complex_id` bigint(20) UNSIGNED NOT NULL,
  `full_name` varchar(150) NOT NULL,
  `email` varchar(190) NOT NULL,
  `phone` varchar(30) DEFAULT NULL,
  `password_hash` varchar(255) NOT NULL,
  `account_status` enum('Pending','Active','Suspended','Disabled','Locked') NOT NULL DEFAULT 'Pending',
  `email_verified` tinyint(1) NOT NULL DEFAULT 0,
  `failed_login_count` smallint(5) UNSIGNED NOT NULL DEFAULT 0,
  `locked_until` datetime DEFAULT NULL,
  `last_login_at` datetime DEFAULT NULL,
  `last_password_change_at` datetime DEFAULT NULL,
  `must_change_password` tinyint(1) NOT NULL DEFAULT 0,
  `auth_version` smallint(5) UNSIGNED NOT NULL DEFAULT 1,
  `is_deleted` tinyint(1) NOT NULL DEFAULT 0,
  `deleted_at` datetime DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `users`
--

INSERT INTO `users` (`user_id`, `role_id`, `complex_id`, `full_name`, `email`, `phone`, `password_hash`, `account_status`, `email_verified`, `failed_login_count`, `locked_until`, `last_login_at`, `last_password_change_at`, `must_change_password`, `auth_version`, `is_deleted`, `deleted_at`, `created_by`, `created_at`, `updated_at`) VALUES
(15, 4, 1, 'Rakindu Fernando', 'rakindufernando@gmail.com', '+94712009223', 'pbkdf2:sha256:600000$lp6bzPb9GFlIMW9Y$1786f90124705e0b2152ea6305397c6683940a5697128cb372ce5ac75f3c3554', 'Active', 1, 0, NULL, '2026-08-31 00:31:23', '2026-08-27 14:08:00', 0, 5, 0, NULL, NULL, '2026-08-17 11:48:08', '2026-08-31 00:31:23'),
(272, 1, 1, 'Akila Dissanayake', 'akila.dissanayake@gmail.com', '+94773884351', 'pbkdf2:sha256:600000$2rMMCYUAa88UAivr$af1a1127aef141ad3e0b61a7c6cf5ae7ff0b87ce25fc9b9bc4fe0b2ea55da5b2', 'Active', 1, 0, NULL, '2026-08-26 16:44:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:30:00', '2026-08-29 14:30:58'),
(273, 1, 1, 'Amanda Perera', 'amanda.perera@outlook.com', '+94707570359', 'pbkdf2:sha256:600000$jUKXt8miGbXaNa96$cb159c9afddfb774703698d96ab7cd4ca18ec02d1d7729f853939b1fe0523f10', 'Active', 1, 0, NULL, '2026-08-30 00:21:07', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:33:00', '2026-08-30 00:21:07'),
(274, 1, 1, 'Anjali Herath', 'anjali.herath@hotmail.com', '+94752728158', 'pbkdf2:sha256:600000$TphgkrmpQART8iuC$e3c8c569d14f8ad20f0b4430be57e697ddba667677576cd34946bdca838e1246', 'Active', 1, 0, NULL, '2026-08-26 17:58:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:00:00', '2026-08-29 14:30:58'),
(275, 1, 1, 'Chamod Wickramasinghe', 'chamod.wickramasinghe@yahoo.com', '+94728075539', 'pbkdf2:sha256:600000$njMeFLVjn94GQMpM$a425e9a8f2041d182d5774ef52570164848251d9f93f188703d7d9e795608a12', 'Active', 1, 0, NULL, '2026-08-26 18:35:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:45:00', '2026-08-29 14:30:58'),
(276, 1, 1, 'Dhanushka Gunawardena', 'dhanushka.gunawardena@icloud.com', '+94758150571', 'pbkdf2:sha256:600000$s8UuzQbJw1dt92CU$3964a1f382043a038313fea4420a299df9d3a63a5c08cbba0513d06236668be8', 'Active', 1, 0, NULL, '2026-08-26 19:12:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:18:00', '2026-08-29 14:30:58'),
(277, 1, 1, 'Dinithi Jayawardena', 'dinithi.jayawardena@live.com', '+94711358681', 'pbkdf2:sha256:600000$fwtnoGnvAoM2FcgB$b62e931b96f08a1afdceac70606878f1086caa3606ae3f90092c5a9a8838a0b8', 'Active', 1, 0, NULL, '2026-08-30 00:22:16', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:06:00', '2026-08-30 00:22:16'),
(278, 1, 1, 'Dulanjali De Silva', 'dulanjali.desilva@proton.me', '+94771810834', 'pbkdf2:sha256:600000$BUq0NstS5S8wClds$70a809fad94a71a410a7fa356edca87ae89dd785e879a31c8fcc5a4cb5511fb4', 'Active', 1, 0, NULL, '2026-08-26 20:26:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:42:00', '2026-08-29 14:30:58'),
(279, 1, 1, 'Gimhani Silva', 'gimhani.silva@msn.com', '+94745174130', 'pbkdf2:sha256:600000$8g0Mfn3zbWRiemnd$1d4906e0511c791beb6a69d3188f8f6e78e206414dd57aaacb1365cf3c22dfe3', 'Active', 1, 0, NULL, '2026-08-27 03:20:21', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:15:00', '2026-08-29 14:30:58'),
(280, 1, 1, 'Hasini Fernando', 'hasini.fernando@gmail.com', '+94769766488', 'pbkdf2:sha256:600000$CYj7Rwh1BgQSHFtS$c59d85e5e578f1fed4a98c0c64d58360096e65663b8145631e437d8582097cc6', 'Active', 1, 0, NULL, '2026-08-26 21:40:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:09:00', '2026-08-29 14:30:58'),
(281, 1, 1, 'Hiruni Samarasinghe', 'hiruni.samarasinghe@outlook.com', '+94783033921', 'pbkdf2:sha256:600000$NHhSIu4iFzJhvziy$a5c9b1a0bb2b54dee2d3ac58312489d807a07c51a332568946d246bf56f95b6d', 'Active', 1, 0, NULL, '2026-08-26 22:17:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:54:00', '2026-08-29 14:30:58'),
(282, 1, 1, 'Imesha Karunaratne', 'imesha.karunaratne@hotmail.com', '+94704183250', 'pbkdf2:sha256:600000$rbHtheTAxhjCRP0J$2c0f96727222e7d0cf69d7f37c646f7d1a00128418f5fc31f2539fb8391ae23c', 'Active', 1, 0, NULL, '2026-08-26 22:54:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:39:00', '2026-08-29 14:30:58'),
(283, 1, 1, 'Ishadi Fernando', 'ishadi.fernando@yahoo.com', '+94705712683', 'pbkdf2:sha256:600000$LT3KfKYdVv9RK1oU$34611ed8f4f665f9ca70d95b0762d031befb339a0aa06dae657b6e2ea71cadc4', 'Active', 1, 0, NULL, '2026-08-23 08:31:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:09:00', '2026-08-29 14:30:58'),
(284, 1, 1, 'Janith Ekanayake', 'janith.ekanayake@icloud.com', '+94753291783', 'pbkdf2:sha256:600000$9NU43YTaWyq6HT6j$8396c1c0cc4f9022f17c08c915676ee6c1f11dee52f7a51768830c2fcf4f422e', 'Active', 1, 0, NULL, '2026-08-23 09:08:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:24:00', '2026-08-29 14:30:58'),
(285, 1, 1, 'Kavindu Silva', 'kavindu.silva@live.com', '+94715547020', 'pbkdf2:sha256:600000$Li2mTnHZ8mN0hwGz$e6b70ee02e3a0180c9604f7919af3707f24ac0529394ad5a60dcd6050ed41b38', 'Active', 1, 0, NULL, '2026-08-23 09:45:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:03:00', '2026-08-29 14:30:58'),
(286, 1, 1, 'Kusal Mendis', 'kusal.mendis@proton.me', '+94780680637', 'pbkdf2:sha256:600000$PcO7rMrvkeyOwMuy$eb1bc17452b1a515177452b7520f80749ff6225fdd5c67ccef62fada843d2064', 'Active', 1, 0, NULL, '2026-08-23 10:22:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:51:00', '2026-08-29 14:30:58'),
(287, 1, 1, 'Lahiru Dilshan', 'lahiru.dilshan@msn.com', '+94741705704', 'pbkdf2:sha256:600000$3njwguJf2FPo1SCF$ce85ee9d5bbded0bae0f0f0de7c2e75cf21f5afab3e3ded0154a489e450110c9', 'Active', 1, 0, NULL, '2026-08-23 10:59:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:36:00', '2026-08-29 14:30:58'),
(288, 1, 1, 'Malith Senanayake', 'malith.senanayake@gmail.com', '+94742740368', 'pbkdf2:sha256:600000$AvPtlgUi5WybOWs8$2980068fffca6fb5d39185c1530cd709295c4057931f9d140746c0c93c43ac97', 'Active', 1, 0, NULL, '2026-08-23 11:36:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:18:00', '2026-08-29 14:30:58'),
(289, 1, 1, 'Manori Senanayake', 'manori.senanayake@outlook.com', '+94751804434', 'pbkdf2:sha256:600000$ryp7xEBKE2aHTLhl$733060d34ded169c7e332537acc52a158498c10c878584648f287646c7901caf', 'Active', 1, 0, NULL, '2026-08-23 12:13:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:48:00', '2026-08-29 14:30:58'),
(290, 1, 1, 'Nadeesha Priyadarshani', 'nadeesha.priyadarshani@hotmail.com', '+94761159170', 'pbkdf2:sha256:600000$kiFv5pPtzdKG6BEG$a3701ae8549f8a9c4c21b544b8e4b267ec930269d3193dbe828c76972eaf2aa9', 'Active', 1, 0, NULL, '2026-08-23 12:50:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:27:00', '2026-08-29 14:30:58'),
(291, 1, 1, 'Nimesh Wijesinghe', 'nimesh.wijesinghe@yahoo.com', '+94769747092', 'pbkdf2:sha256:600000$zUpXdChmJh0sM60z$06464c65cfcc8386fe097ab33f1222f90bb2684670ced986e1618f99fc3a240e', 'Active', 1, 0, NULL, '2026-08-23 13:27:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:12:00', '2026-08-29 14:30:58'),
(292, 1, 1, 'Oshadi Gunasekara', 'oshadi.gunasekara@icloud.com', '+94776361907', 'pbkdf2:sha256:600000$hdgqfV5VY06gX3En$39e4589d51ee9e4b1afe9d0fa21b41d136f9885c4774afb4f01f3d2399abd0ac', 'Active', 1, 0, NULL, '2026-08-23 14:04:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:15:00', '2026-08-29 14:30:58'),
(293, 1, 1, 'Pabasara Wijekoon', 'pabasara.wijekoon@live.com', '+94715342316', 'pbkdf2:sha256:600000$0T1q84IDQTanTJ7Q$9847a44c30a0615e215f0754dbe0b42f5fd16d5694cb49c5be37470f1fa4fde9', 'Active', 1, 0, NULL, '2026-08-23 14:41:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:45:00', '2026-08-29 14:30:58'),
(294, 1, 1, 'Pasindu Bandara', 'pasindu.bandara@proton.me', '+94728956329', 'pbkdf2:sha256:600000$Pv7Wb2Ke0jafNuW8$75a4984ba6769951f579b6ea8acb2c11e5226a9046b97f9bbc6ed0c23c07daaf', 'Active', 1, 0, NULL, '2026-08-23 15:18:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:36:00', '2026-08-29 14:30:58'),
(295, 1, 1, 'Piumi Rathnayake', 'piumi.rathnayake@msn.com', '+94713185144', 'pbkdf2:sha256:600000$YISBnSBxXy4nfpmb$726c0dd94edda061bbc35a903e636173639a77adf9136676a69d74c629a76b0d', 'Active', 1, 0, NULL, '2026-08-23 15:55:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:21:00', '2026-08-29 14:30:58'),
(296, 1, 1, 'Ravindu Lakshan', 'ravindu.lakshan@gmail.com', '+94752823196', 'pbkdf2:sha256:600000$vjcHlNgoZhAEj1Qc$232938bcccb5aff5d54086b97b71e558525c6c839a11ba77b8d590eff810d619', 'Active', 1, 0, NULL, '2026-08-23 16:32:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:57:00', '2026-08-29 14:30:58'),
(297, 1, 1, 'Nethmi Perera', 'nethmi.perera@outlook.com', '+94771924314', 'pbkdf2:sha256:600000$aiyCmaO6lLWN04fr$f4abb377c1c5d6b3850fa587e002f1601dae5823223d0df7b616f0ab747e0773', 'Active', 1, 0, NULL, '2026-08-27 14:25:47', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:00:00', '2026-08-29 14:30:58'),
(298, 1, 1, 'Rukshan Fernando', 'rukshan.fernando@hotmail.com', '+94763653491', 'pbkdf2:sha256:600000$JuIQJeXQL1Kcuqu4$055e02ada83057b7cf84ef4668c06e13ea1ef326d31c94fcefe53c0acfc5fec6', 'Active', 1, 0, NULL, '2026-08-27 14:08:58', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:42:00', '2026-08-29 14:30:58'),
(299, 1, 1, 'Sachini Weerasinghe', 'sachini.weerasinghe@yahoo.com', '+94775752246', 'pbkdf2:sha256:600000$wiEMGKixCtcpjGxM$ece15939bd31d021664661385e8912f9c2a17c7b9443580ddc104121e77afc98', 'Active', 1, 0, NULL, '2026-08-23 18:23:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:33:00', '2026-08-29 14:30:58'),
(300, 1, 1, 'Sandun Jayasekara', 'sandun.jayasekara@icloud.com', '+94746936301', 'pbkdf2:sha256:600000$9g2gEtIP4Q73SxEp$5a73e59f1a788ec825464989497bb436b35d9ade6da8d4e24ab5a77bc35e6fd8', 'Active', 1, 0, NULL, '2026-08-26 18:59:53', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:06:00', '2026-08-29 14:30:58'),
(301, 1, 1, 'Sewwandi Kumari', 'sewwandi.kumari@live.com', '+94764582921', 'pbkdf2:sha256:600000$FCRTe9fYDDVleRJH$008229bacbac630907d21e0b6f65bcbea003a03b33a25d5c6601e425a1fe06df', 'Active', 1, 0, NULL, '2026-08-29 10:50:39', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:21:00', '2026-08-29 14:30:58'),
(302, 1, 1, 'Shashika Madurangi', 'shashika.madurangi@proton.me', '+94764223041', 'pbkdf2:sha256:600000$NlFgMO1rO4fteaVw$6898b301d1c34bc6b191aab2e89a0f3b00afb2a4d1ed62de34878adab2920e56', 'Active', 1, 0, NULL, '2026-08-23 20:14:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:39:00', '2026-08-29 14:30:58'),
(303, 1, 1, 'Shehan Peiris', 'shehan.peiris@msn.com', '+94770390948', 'pbkdf2:sha256:600000$YCAR5gnBtTeqxwnZ$21540d18981d73f6f5a59d7bfc227e9e1d13b11f34daed5cbbc2e3aa65105c1e', 'Active', 1, 0, NULL, '2026-08-23 20:51:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:24:00', '2026-08-29 14:30:58'),
(304, 1, 1, 'Supun Niroshan', 'supun.niroshan@gmail.com', '+94768115270', 'pbkdf2:sha256:600000$RpT0bUCpK3Nn6Qib$c393505e1137ecd95cf396014423340ba883b91e1e7979a78266e58a0e8c512f', 'Active', 1, 0, NULL, '2026-08-23 21:28:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:12:00', '2026-08-29 14:30:58'),
(305, 1, 1, 'Tharushi Perera', 'tharushi.perera@outlook.com', '+94788472925', 'pbkdf2:sha256:600000$U98ZZdyWD7wuXPWh$40d5e3daa46405e8cffddc1074c1f23476f62b10e7b64611dde6e1de8ec000e6', 'Active', 1, 0, NULL, '2026-08-27 02:29:01', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:03:00', '2026-08-29 14:30:58'),
(306, 1, 1, 'Thilini Abeysekara', 'thilini.abeysekara@hotmail.com', '+94753986635', 'pbkdf2:sha256:600000$ijJNfhYhmjmus4dS$eaabdd46623136cf505e1bd942c046340c5ec259572490ee4bf3eae7f9077cd5', 'Active', 1, 0, NULL, '2026-08-30 01:44:03', '2026-08-30 01:43:53', 0, 4, 0, NULL, 15, '2026-08-17 13:27:00', '2026-08-30 01:44:03'),
(307, 1, 1, 'Thiwanka Samarakoon', 'thiwanka.samarakoon@yahoo.com', '+94775980140', 'pbkdf2:sha256:600000$3e0VygInoTz7Y1ed$c63672c87d63b446d0ca485a369dcd5f90c0c0dec08b24c524a6997731706da6', 'Active', 1, 0, NULL, '2026-08-30 10:18:54', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:51:00', '2026-08-30 10:18:54'),
(308, 1, 1, 'Upeksha Madushani', 'upeksha.madushani@icloud.com', '+94703985528', 'pbkdf2:sha256:600000$gpAEh88RhM5ZCwBP$55715c73c24c80c904342895442d8917f7282f47e2f163be97a05657e7c56d63', 'Active', 1, 0, NULL, '2026-08-23 23:56:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 13:48:00', '2026-08-29 14:30:58'),
(309, 1, 1, 'Vihanga Rajapaksha', 'vihanga.rajapaksha@live.com', '+94753440357', 'pbkdf2:sha256:600000$rVq7Fwp6WzsLlfaR$06fab2f14ecd98d5b1ccaf31d1f5971dd9bca324dd540ec757fdf60f6cf8753d', 'Active', 1, 0, NULL, '2026-08-24 00:33:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-17 14:30:00', '2026-08-29 14:30:58'),
(335, 2, 1, 'Dilani Fernando', 'admin@helafixit.lk', '+94725725310', 'pbkdf2:sha256:600000$ThVD1HMdmER6rOPK$f30e6be56c02d2a9bf6a4f0fd30960ae56c211d6078e8db811b233d1cb457f03', 'Active', 1, 0, NULL, '2026-08-30 16:27:17', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-18 09:00:00', '2026-08-30 16:27:17'),
(336, 2, 1, 'Chathurika Senanayake', 'chathurika.senanayake@helafixit.lk', '+94785196517', 'pbkdf2:sha256:600000$sF3C8HsqcLEH0Lcl$ec3cd2cd75db8335081bcc3ca2552a19ed1875f436b5a7e4a9d556749993fc3d', 'Active', 1, 0, NULL, '2026-08-26 18:56:35', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-18 09:48:00', '2026-08-29 14:30:58'),
(337, 2, 1, 'Dinusha Karunaratne', 'dinusha.karunaratne@helafixit.lk', '+94705492379', 'pbkdf2:sha256:600000$T3BOSjTOR3QPh0tR$dac84cbb9d8f66dd3d91b4d978527ba67e6d4867cc79b2c60a96960a72113738', 'Active', 1, 0, NULL, '2026-08-30 00:38:22', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-18 10:12:00', '2026-08-30 00:38:22'),
(338, 2, 1, 'Gayani Rathnayake', 'gayani.rathnayake@helafixit.lk', '+94708476954', 'pbkdf2:sha256:600000$bn4YC5erMJWHmdPO$846f8c1540c359477e688d5b938860f8e842592bbb70ea5df300de46a34469d4', 'Active', 1, 0, NULL, '2026-08-30 10:22:45', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-18 10:36:00', '2026-08-30 10:22:45'),
(339, 2, 1, 'Harini Wijesinghe', 'harini.wijesinghe@helafixit.lk', '+94776488398', 'pbkdf2:sha256:600000$XIZnVxA1fFhXbFF3$c67ef506192d728ce273d77c44941a8afba6fe37a6ab361abd2f4d597b3521b5', 'Active', 1, 0, NULL, '2026-08-30 01:52:02', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-18 09:24:00', '2026-08-30 01:52:02'),
(340, 2, 1, 'Iresha Jayasinghe', 'iresha.jayasinghe@helafixit.lk', '+94760299265', 'pbkdf2:sha256:600000$V8ngnkHU8c6S0Ueb$51e12e715d34e48dbfc0e478bfaeba3dcda0d900af4b76f818d94ad12347a6be', 'Active', 1, 0, NULL, '2026-08-26 18:45:33', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-18 10:00:00', '2026-08-29 14:30:58'),
(341, 2, 1, 'Nadeesha Perera', 'nadeesha.perera@helafixit.lk', '+94766847536', 'pbkdf2:sha256:600000$emzWqWiGvF0SRhJU$55af812289345d8e8b09647aee92c17b00344319f39d9f4ee7313919a9a65073', 'Active', 1, 0, NULL, '2026-08-29 14:10:23', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-18 09:12:00', '2026-08-29 14:30:58'),
(342, 2, 1, 'Sachini De Silva', 'sachini.de.silva@helafixit.lk', '+94770634113', 'pbkdf2:sha256:600000$jK1hb5MeGEFg2HJ3$1724ada9affa93faf7720fed2ce4162bd2840c07e723c0e6cd0e0670bc4cb349', 'Active', 1, 0, NULL, '2026-08-30 16:16:18', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-18 10:48:00', '2026-08-30 16:16:18'),
(343, 2, 1, 'Shalini Abeysekera', 'shalini.abeysekera@helafixit.lk', '+94723498137', 'pbkdf2:sha256:600000$Aud2bdIrsmIjFazG$5389fffec0a6d39fe4292d285586c453b3cdc1df8751835cf179bcdef2cefa01', 'Active', 1, 0, NULL, '2026-08-27 14:10:39', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-18 10:24:00', '2026-08-29 14:30:58'),
(344, 2, 1, 'Tharushi Gunawardena', 'tharushi.gunawardena@helafixit.lk', '+94767341246', 'pbkdf2:sha256:600000$3GZvA3jAcF1suGOn$b81cbc5936c9a5923c282fe2a659171370792e56b358b97e7ed1aa67eee5f0b7', 'Active', 1, 0, NULL, '2026-08-30 01:56:21', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-18 09:36:00', '2026-08-30 01:56:21'),
(350, 3, 1, 'Amila Perera', 'amila.perera.elec@helafixit.lk', '+94745229390', 'pbkdf2:sha256:600000$sRznq7uhJLkwSpYK$525afa21495bc295202784491d08f9fc80ba6adaa673805789646a1944b44c71', 'Active', 1, 0, NULL, '2026-08-25 01:50:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 08:30:00', '2026-08-29 14:30:58'),
(351, 3, 1, 'Asanka Weerasinghe', 'asanka.weerasinghe.other@helafixit.lk', '+94743080409', 'pbkdf2:sha256:600000$0ScopR2WBm3qDKv8$72007f0e633da15eb7d473b08d5d37f18c5835720009ccbcc3e76aeba97c25ed', 'Active', 1, 0, NULL, '2026-08-25 02:27:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 09:50:00', '2026-08-29 14:30:58'),
(352, 3, 1, 'Ashan Senanayake', 'ashan.senanayake.pest@helafixit.lk', '+94759382113', 'pbkdf2:sha256:600000$0BbWwSt8VnGUh7ko$c12da1ff479689869ca9675599637dadf88fa6baf520191bdbab75c66e373d7a', 'Active', 1, 0, NULL, '2026-08-25 03:04:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 14:00:00', '2026-08-29 14:30:58'),
(353, 3, 1, 'Bimal Rathnayake', 'bimal.rathnayake.carp@helafixit.lk', '+94779663412', 'pbkdf2:sha256:600000$el6FUXcJJQuy1jVL$14647c75667a0d1c2396a6b923ea7ae858c47f0f251a467aec49d15082fe3b44', 'Active', 1, 0, NULL, '2026-08-25 03:41:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 14:10:00', '2026-08-29 14:30:58'),
(354, 3, 1, 'Buddhika Silva', 'buddhika.silva.plumb@helafixit.lk', '+94719836177', 'pbkdf2:sha256:600000$VNGaRvlpJjNzhAS8$1c143bb6dd63ea19db5ef5f811dea22b28a7a84bc529665b09f1df2301df1999', 'Active', 1, 0, NULL, '2026-08-25 04:18:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 08:40:00', '2026-08-29 14:30:58'),
(355, 3, 1, 'Chamara Perera', 'chamara.perera.plumb@helafixit.lk', '+94702171883', 'pbkdf2:sha256:600000$iamcI8n8EZowkNmH$d5f4523dae6eb83c6c101382abeea212c8f35ae763700e01d308babbf5834560', 'Active', 1, 0, NULL, '2026-08-25 04:55:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 08:40:00', '2026-08-29 14:30:58'),
(356, 3, 1, 'Chamil Fernando', 'chamil.fernando.lift@helafixit.lk', '+94754120676', 'pbkdf2:sha256:600000$evRsY1emA3Wpzemw$aa8632e7861bd6a317cfe040ac916e4c2f03b7c51848adf645af006b9c4e81c0', 'Active', 1, 0, NULL, '2026-08-25 05:32:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 08:50:00', '2026-08-29 14:30:58'),
(357, 3, 1, 'Charith Peiris', 'charith.peiris.other@helafixit.lk', '+94748249182', 'pbkdf2:sha256:600000$YpZxWPxkflAdrYpv$8964d67b5df8a68421be4b44812b35e0d9d5478ae430e9c6222520f8a18b9958', 'Active', 1, 0, NULL, '2026-08-25 06:09:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 14:20:00', '2026-08-29 14:30:58'),
(358, 3, 1, 'Chathura Bandara', 'chathura.bandara.ac@helafixit.lk', '+94709897629', 'pbkdf2:sha256:600000$TNDSa8hq9psnIoOs$580ef2bb52d912dd274f628e66cf1a9d50792af4c5381c4e3561e8d9b2c74e21', 'Active', 1, 0, NULL, '2026-08-25 06:46:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 13:30:00', '2026-08-29 14:30:58'),
(359, 3, 1, 'Damith Dissanayake', 'damith.dissanayake.gas@helafixit.lk', '+94751269203', 'pbkdf2:sha256:600000$gWZizHiVSyIkCDfH$2a35d55b055dfc1489412fe40007dd7c905ebdc43dee213b5016aa27dcf1a417', 'Active', 1, 0, NULL, '2026-08-25 07:23:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 14:40:00', '2026-08-29 14:30:58'),
(360, 3, 1, 'Darshana Herath', 'darshana.herath.fire@helafixit.lk', '+94760269243', 'pbkdf2:sha256:600000$XBiOO4ySh31N13DU$9eba8957080e24114f4e655ed631594730337ab668b50d1dff9b3d4218823e8f', 'Active', 1, 0, NULL, '2026-08-25 08:00:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 14:30:00', '2026-08-29 14:30:58'),
(361, 3, 1, 'Dinesh Fernando', 'dinesh.fernando.ac@helafixit.lk', '+94708427232', 'pbkdf2:sha256:600000$lWvf9196fGpnudaI$fc93c7cadf672504b49700434eae7a262bba89261c6009725ba4782d28b6c7fe', 'Active', 1, 0, NULL, '2026-08-25 08:37:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 09:00:00', '2026-08-29 14:30:58'),
(362, 3, 1, 'Eranga Wijekoon', 'eranga.wijekoon.struct@helafixit.lk', '+94776500879', 'pbkdf2:sha256:600000$IMLmg4lQoIdnvMlt$abd2b50a5243e8a8358be4505968d749a49879ac32bfd7a96102188e6240cc47', 'Active', 1, 0, NULL, '2026-08-25 09:14:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 14:50:00', '2026-08-29 14:30:58'),
(363, 3, 1, 'Eshan Dissanayake', 'eshan.dissanayake.gas@helafixit.lk', '+94759214261', 'pbkdf2:sha256:600000$cNbD3jfDDLR11LtX$15b4a1eb980054d5aa99efd02c1c5a82ee1d551ec3042d092efb883bb4a54594', 'Active', 1, 0, NULL, '2026-08-25 09:51:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 14:40:00', '2026-08-29 14:30:58'),
(364, 3, 1, 'Fairooz Ahamed', 'fairooz.ahamed.struct@helafixit.lk', '+94768139021', 'pbkdf2:sha256:600000$FIwyREpG0hb7zQK7$c9643913821a37ee726a02980cb12e06a54f709aee12faf6585b2887cf5ebc70', 'Active', 1, 0, NULL, '2026-08-25 10:28:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 14:50:00', '2026-08-29 14:30:58'),
(365, 3, 1, 'Gayan Perera', 'gayan.perera.elec@helafixit.lk', '+94723516946', 'pbkdf2:sha256:600000$ogizMNAmzOfMHexV$bad2b2e279492e3a1cb78688519ed963d1cb8b7819ed18991244fed7b8e43134', 'Active', 1, 0, NULL, '2026-08-30 01:53:20', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 13:00:00', '2026-08-30 01:53:20'),
(366, 3, 1, 'Gihan Samarasinghe', 'gihan.samarasinghe.sec@helafixit.lk', '+94750825245', 'pbkdf2:sha256:600000$IjNCai5K6PWCIOxT$757beac7e375c6f35cc1c432af4f352d147b3d49f254d7500b016db29426d298', 'Active', 1, 0, NULL, '2026-08-25 11:42:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 15:00:00', '2026-08-29 14:30:58'),
(367, 3, 1, 'Harsha Bandara', 'harsha.bandara.ac@helafixit.lk', '+94706471585', 'pbkdf2:sha256:600000$ReqG90UZwCa0575P$1fdcf71b37925521d5201b648aea4cd43a585d92046ec99e6f5c43ae69652a9c', 'Active', 1, 0, NULL, '2026-08-25 12:19:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 09:00:00', '2026-08-29 14:30:58'),
(368, 3, 1, 'Heshan Perera', 'heshan.perera.elec@helafixit.lk', '+94703251601', 'pbkdf2:sha256:600000$BC67ylYEeHB8FoEu$f59c15d686657c6fbb4364000c5a8e211091625809d542bec8dc011eb808a34b', 'Active', 1, 0, NULL, '2026-08-25 12:56:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 08:30:00', '2026-08-29 14:30:58'),
(369, 3, 1, 'Indika Jayawardena', 'indika.jayawardena.drain@helafixit.lk', '+94714802635', 'pbkdf2:sha256:600000$v97feMbzL1TRyilR$34a3d8c2a4808f2222f0c9bb7c930321918231df8e815ebf0a2cdd9c148a3575', 'Active', 1, 0, NULL, '2026-08-26 18:58:40', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 09:10:00', '2026-08-29 14:30:58'),
(370, 3, 1, 'Ishan Silva', 'ishan.silva.plumb@helafixit.lk', '+94759617924', 'pbkdf2:sha256:600000$9C80oMFUDxPZqU1R$9990509f017b7ad69512122fba49e8b567d4bf017b8bf69f1caffbaa1b7efadf', 'Active', 1, 0, NULL, '2026-08-25 14:10:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 08:40:00', '2026-08-29 14:30:58'),
(371, 3, 1, 'Isuru Madushan', 'isuru.madushan.drain@helafixit.lk', '+94741301590', 'pbkdf2:sha256:600000$TjwhXEuLbzPilNPW$4ea9a045358fc7b3983c92533aad0d66171c35c71b4b90137190b2fea8eb7597', 'Active', 1, 0, NULL, '2026-08-29 10:33:52', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 09:10:00', '2026-08-29 14:30:58'),
(372, 3, 1, 'Janaka Rathnayake', 'janaka.rathnayake.carp@helafixit.lk', '+94726571475', 'pbkdf2:sha256:600000$eGvvkZVYLS71wLhw$4813ee3068b4e51bb365a26e3fddfaf73a5ef87d773152d291285a325573f90b', 'Active', 1, 0, NULL, '2026-08-25 15:24:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 14:10:00', '2026-08-29 14:30:58'),
(373, 3, 1, 'Jayantha Fernando', 'jayantha.fernando.lift@helafixit.lk', '+94726658509', 'pbkdf2:sha256:600000$ypHgv7oyAzboNmBb$915943bae41dcbd971ca3fb06a5633135aa6e4f23286ff7ec735d65a41786a2f', 'Active', 1, 0, NULL, '2026-08-26 17:28:20', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 08:50:00', '2026-08-29 14:30:58'),
(374, 3, 1, 'Jeewan Gunawardena', 'jeewan.gunawardena.clean@helafixit.lk', '+94772768280', 'pbkdf2:sha256:600000$G76GJPcVJ0fpq5Ns$697cc8f67197a2fed189ce8ad419521dec99f738ae47a49d3d8b69729c74a906', 'Active', 1, 0, NULL, '2026-08-25 16:38:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 09:20:00', '2026-08-29 14:30:58'),
(375, 3, 1, 'Kanishka Samarasinghe', 'kanishka.samarasinghe.sec@helafixit.lk', '+94709842613', 'pbkdf2:sha256:600000$dYp8xjzbhmuDrpBb$aea469ab320d9c26e8eb0c8e5e5b9974dfa688e09f390e913fcea9b4efd6196e', 'Active', 1, 0, NULL, '2026-08-25 17:15:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 15:00:00', '2026-08-29 14:30:58'),
(376, 3, 1, 'Kasun Maduranga', 'kasun.maduranga.sec@helafixit.lk', '+94759137361', 'pbkdf2:sha256:600000$lUBR1C7MBMTypvZF$063e2618826e793e6fc11d1e1727d32485d204c2b0f5a13d4267e700c9dbfb99', 'Active', 1, 0, NULL, '2026-08-25 17:52:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 10:30:00', '2026-08-29 14:30:58'),
(377, 3, 1, 'Kaveen Bandara', 'kaveen.bandara.ac@helafixit.lk', '+94762469988', 'pbkdf2:sha256:600000$4cSuGKZhIKqA4wk8$353cde3e14862e8eb99d644073c5067a3605a412b63e868875d15bfbe0e26937', 'Active', 1, 0, NULL, '2026-08-25 18:29:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 09:00:00', '2026-08-29 14:30:58'),
(378, 3, 1, 'Kelum Senanayake', 'kelum.senanayake.pest@helafixit.lk', '+94778565547', 'pbkdf2:sha256:600000$FM8bNRHAD04raMla$78af8fc5427a6bd2942a016743df04f8235daeaa20c9b330e3cf68a2a884307d', 'Active', 1, 0, NULL, '2026-08-25 19:06:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 09:30:00', '2026-08-29 14:30:58'),
(379, 3, 1, 'Lahiru Senanayake', 'lahiru.senanayake.pest@helafixit.lk', '+94766045993', 'pbkdf2:sha256:600000$KW96us1OcekEBGl8$0c02a61203002db26105dc5305aa4306f5d70a825f1c053e85c7e1b13f0c4d74', 'Active', 1, 0, NULL, '2026-08-25 19:43:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 09:30:00', '2026-08-29 14:30:58'),
(380, 3, 1, 'Lakmal Rathnayake', 'lakmal.rathnayake.carp@helafixit.lk', '+94740261927', 'pbkdf2:sha256:600000$RXsm5EkvphbHSLL5$8d46ad854a4db4dfb7926f8df6e5663be8a7718951fccf689284c6c31e05a0e3', 'Active', 1, 0, NULL, '2026-08-25 20:20:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 09:40:00', '2026-08-29 14:30:58'),
(381, 3, 1, 'Lasantha Jayawardena', 'lasantha.jayawardena.drain@helafixit.lk', '+94781327019', 'pbkdf2:sha256:600000$xVfROH1PQ40vRNy1$be2f45e33897057ff95a8b532a1301745affc688f49f63df2bf6a781fcb7b7aa', 'Active', 1, 0, NULL, '2026-08-25 20:57:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 09:10:00', '2026-08-29 14:30:58'),
(382, 3, 1, 'Madhuka Senanayake', 'madhuka.senanayake.pest@helafixit.lk', '+94767336097', 'pbkdf2:sha256:600000$LMK09VkUDbiGkRH9$67e3d5f5b6514dfbd1824a59e65d8a99f42536bc1d1cc00a2a2792bbc33bd518', 'Active', 1, 0, NULL, '2026-08-25 21:34:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 14:00:00', '2026-08-29 14:30:58'),
(383, 3, 1, 'Mahesh Karunaratne', 'mahesh.karunaratne.gas@helafixit.lk', '+94719145534', 'pbkdf2:sha256:600000$AC4NCoPq6SmZ0Hi6$745e65c82add900a345ec264ae360738f2183c1d2a294e56ca8a0f0e2277c837', 'Active', 1, 0, NULL, '2026-08-25 22:11:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 10:10:00', '2026-08-29 14:30:58'),
(384, 3, 1, 'Malinga Gunawardena', 'malinga.gunawardena.clean@helafixit.lk', '+94763704496', 'pbkdf2:sha256:600000$Krbp292AxAXgWLBo$5d5805d512941c262af1490b975e352c9642a50cfd7df3705b455586fb9c1860', 'Active', 1, 0, NULL, '2026-08-25 22:48:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 09:20:00', '2026-08-29 14:30:58'),
(385, 3, 1, 'Manjula Herath', 'manjula.herath.fire@helafixit.lk', '+94728079930', 'pbkdf2:sha256:600000$lA6ig4VfeKZt0Oay$30ac38d7dbdc880aba0e8fbe886e99caac9745b0468a40d22c83b8705853c586', 'Active', 1, 0, NULL, '2026-08-25 23:25:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 14:30:00', '2026-08-29 14:30:58'),
(386, 3, 1, 'Milan Peiris', 'milan.peiris.other@helafixit.lk', '+94774524951', 'pbkdf2:sha256:600000$MjCvbJ0pt0ffmHnr$5058d92992e38afc13fba106190aab2858d3fb7a2a34450d22e7e1268c2f4f4c', 'Active', 1, 0, NULL, '2026-08-26 00:02:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 09:50:00', '2026-08-29 14:30:58'),
(387, 3, 1, 'Nalaka Herath', 'nalaka.herath.fire@helafixit.lk', '+94713800732', 'pbkdf2:sha256:600000$YnwuY5X9T2lANSy2$f8a1801a298542b4f3b5fa61d27dabe7f7469424e30ad2b727ed7f56c24b7758', 'Active', 1, 0, NULL, '2026-08-26 00:39:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 10:00:00', '2026-08-29 14:30:58'),
(388, 3, 1, 'Naveen Senanayake', 'naveen.senanayake.pest@helafixit.lk', '+94759401368', 'pbkdf2:sha256:600000$IY7Ofx3W4ucW8eKy$316cef8609144e4e98fcfd75a0ea58652e41bca3d92a1b44a7f0e61a22e54d87', 'Active', 1, 0, NULL, '2026-08-26 01:16:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 09:30:00', '2026-08-29 14:30:58'),
(389, 3, 1, 'Osanda Rathnayake', 'osanda.rathnayake.carp@helafixit.lk', '+94772940726', 'pbkdf2:sha256:600000$iUHsBkjcKefRJRRr$acde94f7ffd9b660c94c1f5a2543f08c6dbac730d5c454ff9d4aa9dbf736f104', 'Active', 1, 0, NULL, '2026-08-26 01:53:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 09:40:00', '2026-08-29 14:30:58'),
(390, 3, 1, 'Oshan Dissanayake', 'oshan.dissanayake.gas@helafixit.lk', '+94780995379', 'pbkdf2:sha256:600000$KBgErt2jIh8e9fEF$f01114566070591ec25ec7709354377d5f22f73a0419ed3230edd2f01ee914b1', 'Active', 1, 0, NULL, '2026-08-26 02:30:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 10:10:00', '2026-08-29 14:30:58'),
(391, 3, 1, 'Prabath Wijekoon', 'prabath.wijekoon.struct@helafixit.lk', '+94727565071', 'pbkdf2:sha256:600000$0X9LovgHrDqE1mMP$5739a7a331c1a351d7590b66523719084b7cea1964c6a49e6c5cee24fd249fd2', 'Active', 1, 0, NULL, '2026-08-26 03:07:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 10:20:00', '2026-08-29 14:30:58'),
(392, 3, 1, 'Pradeep Rajapaksha', 'pradeep.rajapaksha.fire@helafixit.lk', '+94715263177', 'pbkdf2:sha256:600000$zvV32tHe9LQLI2JG$18d3b60669ba6eeea7f18ecb3493665ad4d96b4421d916ca0e0094f5ecafab3c', 'Active', 1, 0, NULL, '2026-08-26 03:44:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 10:00:00', '2026-08-29 14:30:58'),
(393, 3, 1, 'Pubudu Peiris', 'pubudu.peiris.other@helafixit.lk', '+94700166324', 'pbkdf2:sha256:600000$4LNz9ztPhUK4mc9S$5183696c8452b2c1283f51017df7a82a675233af6e299bfdfa1dd6ceb46cbb63', 'Active', 1, 0, NULL, '2026-08-29 13:45:54', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 09:50:00', '2026-08-29 14:30:58'),
(394, 3, 1, 'Ranga Samarasinghe', 'ranga.samarasinghe.sec@helafixit.lk', '+94766552427', 'pbkdf2:sha256:600000$jD4dwRsTd8ulGEBJ$b4ce4f652a3ff0f58fdd19fd0ec07c984692f4b49646efdcff1d132cd32bff34', 'Active', 1, 0, NULL, '2026-08-26 04:58:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 10:30:00', '2026-08-29 14:30:58'),
(395, 3, 1, 'Ravimal Herath', 'ravimal.herath.fire@helafixit.lk', '+94781263061', 'pbkdf2:sha256:600000$cFN5fwSl4JzTrbum$716cf0d9e3d3d402afd5fb6b9e5410961bbd946328bae83174c09710549275da', 'Active', 1, 0, NULL, '2026-08-30 10:23:47', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 10:00:00', '2026-08-30 10:23:47'),
(396, 3, 1, 'Roshan Fernando', 'roshan.fernando.lift@helafixit.lk', '+94746972836', 'pbkdf2:sha256:600000$YQxYqC2SlIOsC9y1$6ef5e83865e8cd9e0cd9a3ae6e90bc0cc3c923d2a865b2826e8c8ba0da7e1a03', 'Active', 1, 0, NULL, '2026-08-26 06:12:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 13:20:00', '2026-08-29 14:30:58'),
(397, 3, 1, 'Ruwan Bandara', 'ruwan.bandara.carp@helafixit.lk', '+94744948255', 'pbkdf2:sha256:600000$uYNwHZ27DfJnPGIl$a90c221c6733dc4b8ebf9b11e8984eed5a9100c88db94307e213d1b33868ccda', 'Active', 1, 0, NULL, '2026-08-26 06:49:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 09:40:00', '2026-08-29 14:30:58'),
(398, 3, 1, 'Sachith De Silva', 'sachith.de.silva.struct@helafixit.lk', '+94786030449', 'pbkdf2:sha256:600000$SGa4AaCJe4TN9zp7$599dded6d7fdf47b27d35dc373d633801b91dccf98610148ed84cb055a297b76', 'Active', 1, 0, NULL, '2026-08-26 07:26:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 10:20:00', '2026-08-29 14:30:58'),
(399, 3, 1, 'Sahan Silva', 'sahan.silva.plumb@helafixit.lk', '+94710173657', 'pbkdf2:sha256:600000$rHGL1QplkiCZ006d$42f2564a2be5e684c81799415515d447893e2401254e1b65dc19a21080076ac8', 'Active', 1, 0, NULL, '2026-08-26 08:03:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 13:10:00', '2026-08-29 14:30:58'),
(400, 3, 1, 'Sajith Dissanayake', 'sajith.dissanayake.gas@helafixit.lk', '+94711165086', 'pbkdf2:sha256:600000$2ouQwCUqQkExtF79$bfe9d4bc4a3f037b640c86a7573531c9993c1955c87da421cedbd8b4f60b79f9', 'Active', 1, 0, NULL, '2026-08-26 08:40:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 10:10:00', '2026-08-29 14:30:58'),
(401, 3, 1, 'Sameera Gunasekara', 'sameera.gunasekara.clean@helafixit.lk', '+94788015340', 'pbkdf2:sha256:600000$UZXbtbTYGQRmzv6R$7dd77c9c1793849ce2a02de9178315bcecba0a2aac69388ebf34044be6e9a76f', 'Active', 1, 0, NULL, '2026-08-26 09:17:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 13:50:00', '2026-08-29 14:30:58'),
(402, 3, 1, 'Sampath Perera', 'sampath.perera.elec@helafixit.lk', '+94711562862', 'pbkdf2:sha256:600000$ErWnQBOt0UW5m4cq$5bdfc37c12b970e309d3858814e1d42fd866fbe6b526ffd3db4d4e235d57c013', 'Active', 1, 0, NULL, '2026-08-31 00:30:13', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 13:00:00', '2026-08-31 00:30:13'),
(403, 3, 1, 'Sanjaya Peiris', 'sanjaya.peiris.other@helafixit.lk', '+94747149365', 'pbkdf2:sha256:600000$bOCSzeHZOpO9kuuw$bd61ea68f58eeff872cc1d27d32cc75d5d1545dd56081957bc0da2431d425478', 'Active', 1, 0, NULL, '2026-08-26 10:31:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 14:20:00', '2026-08-29 14:30:58'),
(404, 3, 1, 'Supun Jayasinghe', 'supun.jayasinghe.lift@helafixit.lk', '+94723465524', 'pbkdf2:sha256:600000$Kfovzw4yizJnFNJK$679fd90ff720264a013d4eb47989a9e790256a4db93bf4d3dcc7e536aedd6088', 'Active', 1, 0, NULL, '2026-08-26 11:08:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 08:50:00', '2026-08-29 14:30:58'),
(405, 3, 1, 'Nuwan Silva', 'tech@helafixit.lk', '+94752132964', 'pbkdf2:sha256:600000$jIfl6Vh2H2uJHbVk$14e26a33c979145f708a18840d0c12197921e02cc70a3ffdee9cbaa662e3c485', 'Active', 1, 0, NULL, '2026-08-29 18:48:11', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 08:30:00', '2026-08-29 18:48:37'),
(406, 3, 1, 'Tharanga Wijekoon', 'tharanga.wijekoon.struct@helafixit.lk', '+94725868299', 'pbkdf2:sha256:600000$pzneivXT47oig8SG$7ba3256f90d652a067ba3c9dd0d0a696b1e29ba08931a90e813d41b265a37ae1', 'Active', 1, 0, NULL, '2026-08-26 12:22:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 10:20:00', '2026-08-29 14:30:58'),
(407, 3, 1, 'Tharindu Kumara', 'tharindu.kumara.clean@helafixit.lk', '+94702452835', 'pbkdf2:sha256:600000$TvIkPnT0oZB8q2KJ$9418a82522c2f44aabe735e30722d042f4a29d4aae1f9b9aaf26daf76a48264e', 'Active', 1, 0, NULL, '2026-08-26 12:59:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 09:20:00', '2026-08-29 14:30:58'),
(408, 3, 1, 'Thilak Silva', 'thilak.silva.plumb@helafixit.lk', '+94779853479', 'pbkdf2:sha256:600000$eoxeGSPUL7e8jkBH$a2005a0bf090d43609866be8ed51550188daa6ef5fafe669b948a11ba92961fb', 'Active', 1, 0, NULL, '2026-08-26 13:36:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 13:10:00', '2026-08-29 14:30:58'),
(409, 3, 1, 'Udara Jayasinghe', 'udara.jayasinghe.drain@helafixit.lk', '+94770569343', 'pbkdf2:sha256:600000$PPLJQtlXcI4MnspH$11b1b4a07d51ab527b06d02445149a88f143ff29e96617e35baa1c3643ee67ca', 'Active', 1, 0, NULL, '2026-08-26 14:13:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-19 13:40:00', '2026-08-29 14:30:58'),
(410, 3, 1, 'Udaya Samarasinghe', 'udaya.samarasinghe.sec@helafixit.lk', '+94783989753', 'pbkdf2:sha256:600000$MZ1quswIVS9Dtz9X$408ed6a654731cff8ed617eeea23d415237179d707abfb8d8309e82058f029ad', 'Active', 1, 0, NULL, '2026-08-30 10:16:21', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 10:30:00', '2026-08-30 10:16:21'),
(411, 3, 1, 'Upul Fernando', 'upul.fernando.lift@helafixit.lk', '+94753371984', 'pbkdf2:sha256:600000$vy7f6qn4FGNzPtA4$47ecbe0222112aecc80f55a0d61a08702810c654446f8293647c4dfded5bae1f', 'Active', 1, 0, NULL, '2026-08-26 15:27:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 13:20:00', '2026-08-29 14:30:58'),
(412, 3, 1, 'Vajira Bandara', 'vajira.bandara.ac@helafixit.lk', '+94729285350', 'pbkdf2:sha256:600000$vyn3TobUGwZzJKkr$55893b31affc086cbae1f1a08149923d8771dedc2d1634a66c6e8ac9b29f5ea0', 'Active', 1, 0, NULL, '2026-08-26 16:04:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 13:30:00', '2026-08-29 14:30:58'),
(413, 3, 1, 'Wasantha Jayawardena', 'wasantha.jayawardena.drain@helafixit.lk', '+94711506997', 'pbkdf2:sha256:600000$lCaYjyArj0HnAz8q$21e245ca3782d53de59015b654203b1e54b5ac39db27c0d0952bcba593f05f88', 'Active', 1, 0, NULL, '2026-08-26 16:41:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 13:40:00', '2026-08-29 14:30:58'),
(414, 3, 1, 'Yohan Gunawardena', 'yohan.gunawardena.clean@helafixit.lk', '+94788004156', 'pbkdf2:sha256:600000$OITkR0oA0Lra4Q4U$70226476bfe461d8a32a85818f50ee2cec47ca79a2fe8663033d77887aec0ccf', 'Active', 1, 0, NULL, '2026-08-26 17:18:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-20 13:50:00', '2026-08-29 14:30:58'),
(477, 4, 1, 'Dulanjana Silva', 'dulanjana.silva.sys@helafixit.lk', '+94745952842', 'pbkdf2:sha256:600000$qLF4PXz7EHeE2LKH$41ec060ccff067ef9f4fdf2396ab77f227522108b67202f337513de36c3b7c18', 'Active', 1, 0, NULL, '2026-08-24 17:09:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-22 10:15:00', '2026-08-29 14:30:58'),
(478, 4, 1, 'Hasini Wickramasinghe', 'hasini.wickramasinghe.sys@helafixit.lk', '+94716975099', 'pbkdf2:sha256:600000$r4Xdknwc8G6LlQxC$13d77892d0efa89dccfed2989d58710156fa02455f70dd09062ea56896ca3056', 'Active', 1, 0, NULL, '2026-08-24 17:46:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-22 10:00:00', '2026-08-29 14:30:58'),
(479, 4, 1, 'Malith Jayawardena', 'malith.jayawardena.sys@helafixit.lk', '+94776626934', 'pbkdf2:sha256:600000$PY1xJshVzRTJGVDP$fe236e562f4f416bd425d0ba63abd0ea28d7d7ecca38d68d53cf00de5c9c0f77', 'Active', 1, 0, NULL, '2026-08-24 18:23:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-22 09:15:00', '2026-08-29 14:30:58'),
(480, 4, 1, 'Nipuni Fernando', 'nipuni.fernando.sys@helafixit.lk', '+94774106642', 'pbkdf2:sha256:600000$bT1vlwESgcfzAa39$5a4f7e2cd2264f02e54fc4b4620fa9c833e072205ca28e487a6fda947bb4cb48', 'Active', 1, 0, NULL, '2026-08-29 18:40:03', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-22 09:30:00', '2026-08-29 18:40:03'),
(481, 4, 1, 'Ravini Gunasekara', 'ravini.gunasekara.sys@helafixit.lk', '+94713126319', 'pbkdf2:sha256:600000$7Jp5JfYik5P3gNmf$c01432ea3498815d5fcb9213b57ab676ff829ab8f55be9f78d16a080261db30a', 'Active', 1, 0, NULL, '2026-08-30 10:05:48', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-22 10:30:00', '2026-08-30 10:05:48'),
(482, 4, 1, 'Kasun Wijesinghe', 'sadmin@helafixit.lk', '+94770156895', 'pbkdf2:sha256:600000$KtpXA7nBY2phCP2R$d164e214c8e6eda96737afe6103967c8b38930711956e6e97748330b22cc5874', 'Active', 1, 0, NULL, '2026-08-24 20:14:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-22 09:00:00', '2026-08-29 14:30:58'),
(483, 4, 1, 'Sajith Bandara', 'sajith.bandara.sys@helafixit.lk', '+94744726956', 'pbkdf2:sha256:600000$gA8xjsgxDGN2KOFh$1ed63c4a9fb98105f1d4f06c59c4cc03c1d5ae993b27635cbe84d5219549c35b', 'Active', 1, 0, NULL, '2026-08-30 04:08:20', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-22 09:45:00', '2026-08-30 04:08:20'),
(484, 1, 1, 'Tharushi Senanayake', 'tharushi.senanayake@proton.me', '+94778029783', 'pbkdf2:sha256:600000$PcwNzvPCydXSKxkI$7edf1f5c1705fb7d9c74afcf7278a8570ab91d30bc061b4e91fce59824324750', 'Active', 1, 0, NULL, '2026-08-24 21:28:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 09:00:00', '2026-08-29 14:30:58'),
(485, 1, 1, 'Pasindu Madushanka', 'pasindu.madushanka@msn.com', '+94753138395', 'pbkdf2:sha256:600000$5q9YsFrOvTconSYE$6e78bd3e6b0502ef93aee2e1d3b3e832ac8ee5eae2ef2c30dca020e50371eb46', 'Active', 1, 0, NULL, '2026-08-24 22:05:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 09:37:00', '2026-08-29 14:30:58'),
(486, 1, 1, 'Oshadi Wijesinghe', 'oshadi.wijesinghe@gmail.com', '+94773514093', 'pbkdf2:sha256:600000$fZLZKqm85k7w9H6K$de73bfb01eb5c5ebc7fb732556eeb2ca2d2cd9daf0ddc058537591de8f02e357', 'Active', 1, 0, NULL, '2026-08-24 22:42:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 10:14:00', '2026-08-29 14:30:58'),
(487, 1, 1, 'Sahan Jayalath', 'sahan.jayalath@outlook.com', '+94767091031', 'pbkdf2:sha256:600000$sQD1qgMjTxIf2bDN$bd7344d0011d87899b618c828311e5766d5827c40809cb2285069fe208b294e1', 'Active', 1, 0, NULL, '2026-08-24 23:19:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 10:51:00', '2026-08-29 14:30:58'),
(488, 1, 1, 'Navodya Bandara', 'navodya.bandara@hotmail.com', '+94740243749', 'pbkdf2:sha256:600000$7n2vcAtf4KOTYxun$ae06ff57f9c814a2ab0614dc75030b6ac79d005e5b42f1cdabe86e38f3b02850', 'Active', 1, 0, NULL, '2026-08-24 23:56:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 11:28:00', '2026-08-29 14:30:58'),
(489, 1, 1, 'Kaveesha Rathnayake', 'kaveesha.rathnayake@yahoo.com', '+94707909329', 'pbkdf2:sha256:600000$LWhterZt5JHlACR1$1eb1e15c7b636bbd687303eccbc5e738e71104f8d9f348ce3f7730bd46654cf1', 'Active', 1, 0, NULL, '2026-08-25 00:33:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 12:05:00', '2026-08-29 14:30:58'),
(490, 1, 1, 'Thisara Abeysekara', 'thisara.abeysekara@icloud.com', '+94756149761', 'pbkdf2:sha256:600000$W7XEX1WjaitbLA0X$ab748c5723b23f6e51bd9d87209246620f098c4563d7d776b987643c2ef7c0f8', 'Active', 1, 0, NULL, '2026-08-25 01:10:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 12:42:00', '2026-08-29 14:30:58'),
(491, 1, 1, 'Chathuni Gamage', 'chathuni.gamage@live.com', '+94780398010', 'pbkdf2:sha256:600000$4n9HiJuXFSkSCqWI$bc933618771d9056995d810801e84eaa7e409e2c494b8f49de3194836a61d069', 'Active', 1, 0, NULL, '2026-08-25 01:47:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 13:19:00', '2026-08-29 14:30:58'),
(492, 1, 1, 'Duleeka Ranasinghe', 'duleeka.ranasinghe@proton.me', '+94728964377', 'pbkdf2:sha256:600000$HRlK72xXIM8orPmo$209f32916b81297e4db7e7934514661b02dab28b4e91ce02e2caa5ed06f45e8c', 'Active', 1, 0, NULL, '2026-08-25 02:24:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 13:56:00', '2026-08-29 14:30:58'),
(493, 1, 1, 'Sachin Fernando', 'sachin.fernando@msn.com', '+94774365504', 'pbkdf2:sha256:600000$GLzJAT9Qmw8oNKgT$56b6ac344dde1075c26b78bfd243b8453092ab0c634602c5511e95cb8b601009', 'Active', 1, 0, NULL, '2026-08-25 03:01:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 14:33:00', '2026-08-29 14:30:58'),
(494, 1, 1, 'Nimesha Weerasinghe', 'nimesha.weerasinghe@gmail.com', '+94766472168', 'pbkdf2:sha256:600000$Z4l4ssdZmHsMF6eg$a0cfcfb19c2ff9c041bb68cf4defecae3c0320e58dd28d969f9790a83e7a0bf5', 'Active', 1, 0, NULL, '2026-08-25 03:38:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 15:10:00', '2026-08-29 14:30:58'),
(495, 1, 1, 'Lasith Perera', 'lasith.perera@outlook.com', '+94715205774', 'pbkdf2:sha256:600000$TGEv8kJHrNBgcJYt$25391db05d9a03a4c4b1d16547cabd820e3bab09ae8f00133c04e105bc78379d', 'Active', 1, 0, NULL, '2026-08-25 04:15:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 15:47:00', '2026-08-29 14:30:58'),
(496, 1, 1, 'Piumi Gunasekara', 'piumi.gunasekara@hotmail.com', '+94770013195', 'pbkdf2:sha256:600000$pM003XCUX4ihqpZq$35d852835933faa2976445cd214e4b05c2f14a6ccc2283ff7f4eac97dc3bd7f9', 'Active', 1, 0, NULL, '2026-08-30 16:26:36', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 16:24:00', '2026-08-30 16:26:36'),
(497, 1, 1, 'Ravindu Pathirana', 'ravindu.pathirana@yahoo.com', '+94725485072', 'pbkdf2:sha256:600000$Dv3Rn8ZHjAQqsVTd$2bac8f49e3b9a6d4c4056def97b0fb17ed0294ac8198c023dcb7f81a3cb8727e', 'Active', 1, 0, NULL, '2026-08-25 05:29:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 17:01:00', '2026-08-29 14:30:58'),
(498, 1, 1, 'Himashi Wickramanayake', 'himashi.wickramanayake@icloud.com', '+94781695767', 'pbkdf2:sha256:600000$OJmNw3mujKLu2DJU$ad4004e6429deca46b7bf40edacd2df8ef90cf3858062e595271696a8afb6618', 'Active', 1, 0, NULL, '2026-08-30 16:33:06', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 17:38:00', '2026-08-30 16:33:06'),
(499, 1, 1, 'Kavisha Maduranga', 'kavisha.maduranga@live.com', '+94743495895', 'pbkdf2:sha256:600000$zaTmngv6iZnbA1CS$d2045d57dae11641b44eb15e57b93ab6e636aea4023b2d7ea42fc41063801478', 'Active', 1, 0, NULL, '2026-08-29 20:09:30', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 18:15:00', '2026-08-29 20:09:30'),
(500, 1, 1, 'Senuri De Alwis', 'senuri.dealwis@proton.me', '+94757662815', 'pbkdf2:sha256:600000$53uMQQwVWHH2auHf$b562175128d49120ccf7da67bf9a83816e0dd6405ea31578fca0f73a7465dd0a', 'Active', 1, 0, NULL, '2026-08-25 07:20:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 18:52:00', '2026-08-29 14:30:58'),
(501, 1, 1, 'Ashen Rodrigo', 'ashen.rodrigo@msn.com', '+94759585047', 'pbkdf2:sha256:600000$yc9tiL4uJJp2Vdt4$ead8d365532516b83265a61dbc8c570a88e786c11048b27990d112c7be1d684e', 'Active', 1, 0, NULL, '2026-08-31 00:29:19', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 19:29:00', '2026-08-31 00:29:19'),
(502, 1, 1, 'Thilini Edirisinghe', 'thilini.edirisinghe@gmail.com', '+94778741794', 'pbkdf2:sha256:600000$180lYfo0Lz3k9c3o$fd2c3c2db0087af5c6db7afc28f2c6ff366c15190f2295c95838274e5dbfeab5', 'Active', 1, 0, NULL, '2026-08-25 08:34:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 20:06:00', '2026-08-29 14:30:58'),
(503, 1, 1, 'Malith Peiris', 'malith.peiris@outlook.com', '+94740843519', 'pbkdf2:sha256:600000$0dtiSBnxNsLgCQLA$509da0f4820dec5d818c8016e96b89ecba3da360c21371d4583bf7a7ab92ac6c', 'Active', 1, 0, NULL, '2026-08-25 09:11:00', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 20:43:00', '2026-08-29 14:30:58'),
(504, 1, 1, 'Vihanga Samarawickrama', 'vihanga.samarawickrama@hotmail.com', '+94720377142', 'pbkdf2:sha256:600000$12Vr07SADGtJhl96$7b963199f0e4d952b221b1045b1349b8fd2c50108ae3512265809400ee982385', 'Active', 1, 0, NULL, '2026-08-29 12:25:24', '2026-08-27 14:08:00', 0, 2, 0, NULL, 15, '2026-08-21 21:20:00', '2026-08-29 14:30:58'),
(505, 1, 1, 'Dinuka Nawaratne', 'dinuka.nawaratne@yahoo.com', '+94719677453', 'pbkdf2:sha256:600000$Gd8EaXo41leb4MKR$965cc5e15a14d02bfd6c0b40c52f6deeff53c762d7247c2b573d9b3cb43a6ad3', 'Active', 1, 0, NULL, '2026-08-30 10:07:19', '2026-08-30 10:07:06', 0, 7, 0, NULL, 15, '2026-08-21 21:57:00', '2026-08-30 10:07:19'),
(506, 1, 1, 'Savindi Perera', 'savindi.perera26@gmail.com', '+94770125001', 'pbkdf2:sha256:600000$n0ZzBFWOsYZiBchb$4725c32b32360aab17f8fecfa72c530cb23c079391f0a9ed1a562e3a613a7ef7', 'Suspended', 1, 0, NULL, '2026-08-29 18:38:34', '2026-08-29 18:38:26', 0, 7, 0, NULL, 15, '2026-08-29 14:04:27', '2026-08-30 01:42:06'),
(507, 1, 1, 'Rakindu Fernando', 'nirmalfernando@gmail.com', '+94722009223', 'pbkdf2:sha256:600000$QatScGxYpLSdlTfF$051e2855334d89af9daa211041861195f06e5049d151093110f6868b1b026eb2', 'Active', 1, 0, NULL, '2026-08-30 13:38:34', '2026-08-29 14:10:46', 0, 1, 0, NULL, 341, '2026-08-29 14:10:46', '2026-08-30 13:38:34');

--
-- Triggers `users`
--
DELIMITER $$
CREATE TRIGGER `trg_users_email_before_insert` BEFORE INSERT ON `users` FOR EACH ROW BEGIN
    SET NEW.email = LOWER(TRIM(NEW.email));
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_users_email_before_update` BEFORE UPDATE ON `users` FOR EACH ROW BEGIN
    SET NEW.email = LOWER(TRIM(NEW.email));
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_admin_dashboard_metrics`
-- (See below for the actual view)
--
CREATE TABLE `vw_admin_dashboard_metrics` (
`open_tickets` decimal(22,0)
,`emergency_tickets` decimal(22,0)
,`high_risk_tickets` decimal(22,0)
,`urgent_unassigned` decimal(22,0)
,`duplicate_tickets` decimal(22,0)
,`resolved_or_closed` decimal(22,0)
,`average_resolution_minutes` decimal(22,1)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_ai_review_queue`
-- (See below for the actual view)
--
CREATE TABLE `vw_ai_review_queue` (
`prediction_id` bigint(20) unsigned
,`ticket_id` bigint(20) unsigned
,`ticket_number` varchar(40)
,`subject` varchar(180)
,`description` longtext
,`predicted_priority` enum('Emergency','High','Medium','Low')
,`priority_confidence` decimal(6,5)
,`risk_score` decimal(5,2)
,`risk_level` enum('Low','Medium','High','Critical')
,`safety_flag` tinyint(1)
,`safety_warning` varchar(1000)
,`duplicate_flag` tinyint(1)
,`duplicate_similarity` decimal(6,5)
,`manual_review_required` tinyint(1)
,`review_status` enum('Pending','Accepted','Corrected','Rejected','Auto Accepted')
,`processed_at` datetime
,`predicted_category` varchar(100)
,`recommended_skill` varchar(100)
,`recommended_technician` varchar(150)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_category_report`
-- (See below for the actual view)
--
CREATE TABLE `vw_category_report` (
`category_name` varchar(100)
,`ticket_count` bigint(21)
,`emergency_count` decimal(22,0)
,`average_risk_score` decimal(6,2)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_duplicate_review`
-- (See below for the actual view)
--
CREATE TABLE `vw_duplicate_review` (
`duplicate_match_id` bigint(20) unsigned
,`source_ticket_number` varchar(40)
,`source_subject` varchar(180)
,`matched_ticket_number` varchar(40)
,`matched_subject` varchar(180)
,`similarity_score` decimal(6,5)
,`location_match_score` decimal(6,5)
,`match_status` enum('Pending','Confirmed','Rejected','Linked')
,`created_at` datetime
,`reviewed_at` datetime
,`reviewed_by_name` varchar(150)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_emergency_queue`
-- (See below for the actual view)
--
CREATE TABLE `vw_emergency_queue` (
`ticket_id` bigint(20) unsigned
,`ticket_number` varchar(40)
,`subject` varchar(180)
,`current_priority` enum('Emergency','High','Medium','Low')
,`current_risk_score` decimal(5,2)
,`current_risk_level` enum('Low','Medium','High','Critical')
,`current_status` enum('Submitted','Analysing','Awaiting Review','Urgent Unassigned','Auto Assigned','Assigned','Accepted','In Progress','On Hold','Resolved','Closed','Reopened','Cancelled')
,`submitted_at` datetime
,`block_code` varchar(50)
,`floor_name` varchar(80)
,`area_name` varchar(100)
,`assignment_id` bigint(20) unsigned
,`assignment_method` enum('Manual','Auto Emergency','Reassignment')
,`assignment_status` enum('Assigned','Accepted','Declined','In Progress','On Hold','Completed','Cancelled','Reassigned')
,`technician_name` varchar(150)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_priority_report`
-- (See below for the actual view)
--
CREATE TABLE `vw_priority_report` (
`priority_name` varchar(12)
,`ticket_count` bigint(21)
,`average_risk_score` decimal(6,2)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_resident_ticket_summary`
-- (See below for the actual view)
--
CREATE TABLE `vw_resident_ticket_summary` (
`resident_id` bigint(20) unsigned
,`resident_name` varchar(150)
,`total_tickets` bigint(21)
,`active_tickets` decimal(22,0)
,`emergency_tickets` decimal(22,0)
,`closed_tickets` decimal(22,0)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_technician_workload`
-- (See below for the actual view)
--
CREATE TABLE `vw_technician_workload` (
`technician_id` bigint(20) unsigned
,`employee_code` varchar(50)
,`technician_name` varchar(150)
,`phone` varchar(30)
,`availability` enum('Available','Busy','Off Duty','On Leave')
,`current_workload` smallint(5) unsigned
,`max_active_jobs` smallint(5) unsigned
,`emergency_eligible` tinyint(1)
,`can_work_after_hours` tinyint(1)
,`rating` decimal(3,2)
,`assigned_block` varchar(50)
,`skills` mediumtext
,`calculated_active_jobs` bigint(21)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_ticket_details`
-- (See below for the actual view)
--
CREATE TABLE `vw_ticket_details` (
`ticket_id` bigint(20) unsigned
,`ticket_number` varchar(40)
,`subject` varchar(180)
,`description` longtext
,`language_type` enum('English','Sinhala','Singlish','Mixed','Unknown')
,`asset_type` varchar(100)
,`current_priority` enum('Emergency','High','Medium','Low')
,`current_risk_score` decimal(5,2)
,`current_risk_level` enum('Low','Medium','High','Critical')
,`current_status` enum('Submitted','Analysing','Awaiting Review','Urgent Unassigned','Auto Assigned','Assigned','Accepted','In Progress','On Hold','Resolved','Closed','Reopened','Cancelled')
,`safety_flag` tinyint(1)
,`duplicate_flag` tinyint(1)
,`manual_review_required` tinyint(1)
,`submitted_at` datetime
,`updated_at` datetime
,`resident_name` varchar(150)
,`resident_email` varchar(190)
,`block_code` varchar(50)
,`floor_name` varchar(80)
,`unit_number` varchar(40)
,`area_name` varchar(100)
,`current_category` varchar(100)
,`current_assignment_id` bigint(20) unsigned
,`assignment_method` enum('Manual','Auto Emergency','Reassignment')
,`assignment_status` enum('Assigned','Accepted','Declined','In Progress','On Hold','Completed','Cancelled','Reassigned')
,`assigned_at` datetime
,`technician_id` bigint(20) unsigned
,`technician_name` varchar(150)
,`technician_availability` enum('Available','Busy','Off Duty','On Leave')
);

-- --------------------------------------------------------

--
-- Structure for view `vw_admin_dashboard_metrics`
--
DROP TABLE IF EXISTS `vw_admin_dashboard_metrics`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_admin_dashboard_metrics`  AS SELECT sum(case when `maintenance_tickets`.`current_status` not in ('Closed','Cancelled') then 1 else 0 end) AS `open_tickets`, sum(case when `maintenance_tickets`.`current_priority` = 'Emergency' and `maintenance_tickets`.`current_status` not in ('Closed','Cancelled') then 1 else 0 end) AS `emergency_tickets`, sum(case when `maintenance_tickets`.`current_risk_level` in ('High','Critical') and `maintenance_tickets`.`current_status` not in ('Closed','Cancelled') then 1 else 0 end) AS `high_risk_tickets`, sum(case when `maintenance_tickets`.`current_status` = 'Urgent Unassigned' then 1 else 0 end) AS `urgent_unassigned`, sum(case when `maintenance_tickets`.`duplicate_flag` = 1 and `maintenance_tickets`.`current_status` not in ('Closed','Cancelled') then 1 else 0 end) AS `duplicate_tickets`, sum(case when `maintenance_tickets`.`current_status` in ('Resolved','Closed') then 1 else 0 end) AS `resolved_or_closed`, round(avg(case when `maintenance_tickets`.`resolved_at` is not null then timestampdiff(MINUTE,`maintenance_tickets`.`submitted_at`,`maintenance_tickets`.`resolved_at`) end),1) AS `average_resolution_minutes` FROM `maintenance_tickets` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_ai_review_queue`
--
DROP TABLE IF EXISTS `vw_ai_review_queue`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_ai_review_queue`  AS SELECT `p`.`prediction_id` AS `prediction_id`, `p`.`ticket_id` AS `ticket_id`, `t`.`ticket_number` AS `ticket_number`, `t`.`subject` AS `subject`, `t`.`description` AS `description`, `p`.`predicted_priority` AS `predicted_priority`, `p`.`priority_confidence` AS `priority_confidence`, `p`.`risk_score` AS `risk_score`, `p`.`risk_level` AS `risk_level`, `p`.`safety_flag` AS `safety_flag`, `p`.`safety_warning` AS `safety_warning`, `p`.`duplicate_flag` AS `duplicate_flag`, `p`.`duplicate_similarity` AS `duplicate_similarity`, `p`.`manual_review_required` AS `manual_review_required`, `p`.`review_status` AS `review_status`, `p`.`processed_at` AS `processed_at`, `c`.`name` AS `predicted_category`, `s`.`skill_name` AS `recommended_skill`, `tech_user`.`full_name` AS `recommended_technician` FROM (((((`ai_predictions` `p` join `maintenance_tickets` `t` on(`t`.`ticket_id` = `p`.`ticket_id`)) left join `issue_categories` `c` on(`c`.`category_id` = `p`.`predicted_category_id`)) left join `skills` `s` on(`s`.`skill_id` = `p`.`recommended_skill_id`)) left join `technician_profiles` `tp` on(`tp`.`technician_id` = `p`.`recommended_technician_id`)) left join `users` `tech_user` on(`tech_user`.`user_id` = `tp`.`user_id`)) WHERE `p`.`is_current` = 1 AND (`p`.`manual_review_required` = 1 OR `p`.`review_status` = 'Pending') ;

-- --------------------------------------------------------

--
-- Structure for view `vw_category_report`
--
DROP TABLE IF EXISTS `vw_category_report`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_category_report`  AS SELECT coalesce(`ic`.`name`,'Unclassified') AS `category_name`, count(0) AS `ticket_count`, sum(case when `t`.`current_priority` = 'Emergency' then 1 else 0 end) AS `emergency_count`, round(avg(`t`.`current_risk_score`),2) AS `average_risk_score` FROM (`maintenance_tickets` `t` left join `issue_categories` `ic` on(`ic`.`category_id` = `t`.`current_category_id`)) GROUP BY coalesce(`ic`.`name`,'Unclassified') ;

-- --------------------------------------------------------

--
-- Structure for view `vw_duplicate_review`
--
DROP TABLE IF EXISTS `vw_duplicate_review`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_duplicate_review`  AS SELECT `dm`.`duplicate_match_id` AS `duplicate_match_id`, `source_t`.`ticket_number` AS `source_ticket_number`, `source_t`.`subject` AS `source_subject`, `matched_t`.`ticket_number` AS `matched_ticket_number`, `matched_t`.`subject` AS `matched_subject`, `dm`.`similarity_score` AS `similarity_score`, `dm`.`location_match_score` AS `location_match_score`, `dm`.`match_status` AS `match_status`, `dm`.`created_at` AS `created_at`, `dm`.`reviewed_at` AS `reviewed_at`, `reviewer`.`full_name` AS `reviewed_by_name` FROM (((`duplicate_matches` `dm` join `maintenance_tickets` `source_t` on(`source_t`.`ticket_id` = `dm`.`source_ticket_id`)) join `maintenance_tickets` `matched_t` on(`matched_t`.`ticket_id` = `dm`.`matched_ticket_id`)) left join `users` `reviewer` on(`reviewer`.`user_id` = `dm`.`reviewed_by`)) ;

-- --------------------------------------------------------

--
-- Structure for view `vw_emergency_queue`
--
DROP TABLE IF EXISTS `vw_emergency_queue`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_emergency_queue`  AS SELECT `t`.`ticket_id` AS `ticket_id`, `t`.`ticket_number` AS `ticket_number`, `t`.`subject` AS `subject`, `t`.`current_priority` AS `current_priority`, `t`.`current_risk_score` AS `current_risk_score`, `t`.`current_risk_level` AS `current_risk_level`, `t`.`current_status` AS `current_status`, `t`.`submitted_at` AS `submitted_at`, `b`.`block_code` AS `block_code`, `f`.`name` AS `floor_name`, `a`.`name` AS `area_name`, `ta`.`assignment_id` AS `assignment_id`, `ta`.`assignment_method` AS `assignment_method`, `ta`.`assignment_status` AS `assignment_status`, `tu`.`full_name` AS `technician_name` FROM ((((((`maintenance_tickets` `t` join `buildings` `b` on(`b`.`building_id` = `t`.`building_id`)) join `floors` `f` on(`f`.`floor_id` = `t`.`floor_id`)) left join `areas` `a` on(`a`.`area_id` = `t`.`area_id`)) left join `ticket_assignments` `ta` on(`ta`.`ticket_id` = `t`.`ticket_id` and `ta`.`is_current` = 1)) left join `technician_profiles` `tp` on(`tp`.`technician_id` = `ta`.`technician_id`)) left join `users` `tu` on(`tu`.`user_id` = `tp`.`user_id`)) WHERE `t`.`current_priority` = 'Emergency' OR `t`.`current_risk_level` = 'Critical' OR `t`.`current_status` in ('Urgent Unassigned','Auto Assigned') ;

-- --------------------------------------------------------

--
-- Structure for view `vw_priority_report`
--
DROP TABLE IF EXISTS `vw_priority_report`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_priority_report`  AS SELECT coalesce(`maintenance_tickets`.`current_priority`,'Unclassified') AS `priority_name`, count(0) AS `ticket_count`, round(avg(`maintenance_tickets`.`current_risk_score`),2) AS `average_risk_score` FROM `maintenance_tickets` GROUP BY coalesce(`maintenance_tickets`.`current_priority`,'Unclassified') ;

-- --------------------------------------------------------

--
-- Structure for view `vw_resident_ticket_summary`
--
DROP TABLE IF EXISTS `vw_resident_ticket_summary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_resident_ticket_summary`  AS SELECT `rp`.`resident_id` AS `resident_id`, `u`.`full_name` AS `resident_name`, count(`t`.`ticket_id`) AS `total_tickets`, sum(case when `t`.`current_status` not in ('Closed','Cancelled') then 1 else 0 end) AS `active_tickets`, sum(case when `t`.`current_priority` = 'Emergency' and `t`.`current_status` not in ('Closed','Cancelled') then 1 else 0 end) AS `emergency_tickets`, sum(case when `t`.`current_status` = 'Closed' then 1 else 0 end) AS `closed_tickets` FROM ((`resident_profiles` `rp` join `users` `u` on(`u`.`user_id` = `rp`.`user_id`)) left join `maintenance_tickets` `t` on(`t`.`resident_id` = `rp`.`resident_id`)) GROUP BY `rp`.`resident_id`, `u`.`full_name` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_technician_workload`
--
DROP TABLE IF EXISTS `vw_technician_workload`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_technician_workload`  AS SELECT `tp`.`technician_id` AS `technician_id`, `tp`.`employee_code` AS `employee_code`, `u`.`full_name` AS `technician_name`, `u`.`phone` AS `phone`, `tp`.`availability` AS `availability`, `tp`.`current_workload` AS `current_workload`, `tp`.`max_active_jobs` AS `max_active_jobs`, `tp`.`emergency_eligible` AS `emergency_eligible`, `tp`.`can_work_after_hours` AS `can_work_after_hours`, `tp`.`rating` AS `rating`, `b`.`block_code` AS `assigned_block`, `skill_list`.`skills` AS `skills`, coalesce(`job_count`.`calculated_active_jobs`,0) AS `calculated_active_jobs` FROM ((((`technician_profiles` `tp` join `users` `u` on(`u`.`user_id` = `tp`.`user_id`)) left join `buildings` `b` on(`b`.`building_id` = `tp`.`assigned_building_id`)) left join (select `ts`.`technician_id` AS `technician_id`,group_concat(`s`.`skill_name` order by `ts`.`is_primary` DESC,`s`.`skill_name` ASC separator ', ') AS `skills` from (`technician_skills` `ts` join `skills` `s` on(`s`.`skill_id` = `ts`.`skill_id`)) group by `ts`.`technician_id`) `skill_list` on(`skill_list`.`technician_id` = `tp`.`technician_id`)) left join (select `ticket_assignments`.`technician_id` AS `technician_id`,count(0) AS `calculated_active_jobs` from `ticket_assignments` where `ticket_assignments`.`is_current` = 1 and `ticket_assignments`.`assignment_status` in ('Assigned','Accepted','In Progress','On Hold') group by `ticket_assignments`.`technician_id`) `job_count` on(`job_count`.`technician_id` = `tp`.`technician_id`)) ;

-- --------------------------------------------------------

--
-- Structure for view `vw_ticket_details`
--
DROP TABLE IF EXISTS `vw_ticket_details`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_ticket_details`  AS SELECT `t`.`ticket_id` AS `ticket_id`, `t`.`ticket_number` AS `ticket_number`, `t`.`subject` AS `subject`, `t`.`description` AS `description`, `t`.`language_type` AS `language_type`, `t`.`asset_type` AS `asset_type`, `t`.`current_priority` AS `current_priority`, `t`.`current_risk_score` AS `current_risk_score`, `t`.`current_risk_level` AS `current_risk_level`, `t`.`current_status` AS `current_status`, `t`.`safety_flag` AS `safety_flag`, `t`.`duplicate_flag` AS `duplicate_flag`, `t`.`manual_review_required` AS `manual_review_required`, `t`.`submitted_at` AS `submitted_at`, `t`.`updated_at` AS `updated_at`, `ru`.`full_name` AS `resident_name`, `ru`.`email` AS `resident_email`, `b`.`block_code` AS `block_code`, `f`.`name` AS `floor_name`, coalesce(`un`.`unit_number`,`t`.`unit_number_snapshot`) AS `unit_number`, `a`.`name` AS `area_name`, `ic`.`name` AS `current_category`, `ta`.`assignment_id` AS `current_assignment_id`, `ta`.`assignment_method` AS `assignment_method`, `ta`.`assignment_status` AS `assignment_status`, `ta`.`assigned_at` AS `assigned_at`, `tp`.`technician_id` AS `technician_id`, `tu`.`full_name` AS `technician_name`, `tp`.`availability` AS `technician_availability` FROM ((((((((((`maintenance_tickets` `t` join `resident_profiles` `rp` on(`rp`.`resident_id` = `t`.`resident_id`)) join `users` `ru` on(`ru`.`user_id` = `rp`.`user_id`)) join `buildings` `b` on(`b`.`building_id` = `t`.`building_id`)) join `floors` `f` on(`f`.`floor_id` = `t`.`floor_id`)) left join `units` `un` on(`un`.`unit_id` = `t`.`unit_id`)) left join `areas` `a` on(`a`.`area_id` = `t`.`area_id`)) left join `issue_categories` `ic` on(`ic`.`category_id` = `t`.`current_category_id`)) left join `ticket_assignments` `ta` on(`ta`.`ticket_id` = `t`.`ticket_id` and `ta`.`is_current` = 1)) left join `technician_profiles` `tp` on(`tp`.`technician_id` = `ta`.`technician_id`)) left join `users` `tu` on(`tu`.`user_id` = `tp`.`user_id`)) ;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `ai_corrections`
--
ALTER TABLE `ai_corrections`
  ADD PRIMARY KEY (`correction_id`),
  ADD KEY `fk_ai_correction_category` (`corrected_category_id`),
  ADD KEY `fk_ai_correction_skill` (`corrected_skill_id`),
  ADD KEY `fk_ai_correction_technician` (`corrected_technician_id`),
  ADD KEY `idx_ai_corrections_prediction` (`prediction_id`,`created_at`),
  ADD KEY `idx_ai_corrections_user` (`corrected_by`,`created_at`);

--
-- Indexes for table `ai_predictions`
--
ALTER TABLE `ai_predictions`
  ADD PRIMARY KEY (`prediction_id`),
  ADD KEY `fk_prediction_category` (`predicted_category_id`),
  ADD KEY `fk_prediction_duplicate_ticket` (`duplicate_ticket_id`),
  ADD KEY `fk_prediction_skill` (`recommended_skill_id`),
  ADD KEY `fk_prediction_technician` (`recommended_technician_id`),
  ADD KEY `idx_predictions_ticket_current` (`ticket_id`,`is_current`,`processed_at`),
  ADD KEY `idx_predictions_review` (`review_status`,`manual_review_required`,`processed_at`),
  ADD KEY `idx_predictions_priority_risk` (`predicted_priority`,`risk_level`),
  ADD KEY `idx_predictions_model` (`model_version_id`);

--
-- Indexes for table `apartment_admin_profiles`
--
ALTER TABLE `apartment_admin_profiles`
  ADD PRIMARY KEY (`admin_id`),
  ADD UNIQUE KEY `uq_admin_profile_user` (`user_id`),
  ADD KEY `fk_admin_profile_building` (`primary_building_id`);

--
-- Indexes for table `apartment_complexes`
--
ALTER TABLE `apartment_complexes`
  ADD PRIMARY KEY (`complex_id`),
  ADD UNIQUE KEY `uq_apartment_complex_name` (`name`);

--
-- Indexes for table `areas`
--
ALTER TABLE `areas`
  ADD PRIMARY KEY (`area_id`),
  ADD UNIQUE KEY `uq_area_location` (`building_id`,`floor_id`,`name`),
  ADD KEY `fk_areas_floor` (`floor_id`),
  ADD KEY `idx_areas_building_floor` (`building_id`,`floor_id`),
  ADD KEY `idx_areas_status` (`status`);

--
-- Indexes for table `audit_logs`
--
ALTER TABLE `audit_logs`
  ADD PRIMARY KEY (`audit_id`),
  ADD KEY `idx_audit_entity` (`entity_type`,`entity_id`,`created_at`),
  ADD KEY `idx_audit_user` (`user_id`,`created_at`),
  ADD KEY `idx_audit_action` (`action_type`,`created_at`),
  ADD KEY `idx_audit_created` (`created_at`),
  ADD KEY `idx_stage5_audit_filter` (`action_type`,`entity_type`,`created_at`);

--
-- Indexes for table `backup_records`
--
ALTER TABLE `backup_records`
  ADD PRIMARY KEY (`backup_id`),
  ADD KEY `fk_backup_started_by` (`started_by`),
  ADD KEY `fk_backup_restored_by` (`restored_by`),
  ADD KEY `idx_backup_status_time` (`backup_status`,`started_at`);

--
-- Indexes for table `buildings`
--
ALTER TABLE `buildings`
  ADD PRIMARY KEY (`building_id`),
  ADD UNIQUE KEY `uq_building_code_per_complex` (`complex_id`,`block_code`),
  ADD KEY `idx_buildings_status` (`status`);

--
-- Indexes for table `category_skill_mappings`
--
ALTER TABLE `category_skill_mappings`
  ADD PRIMARY KEY (`category_skill_mapping_id`),
  ADD UNIQUE KEY `uq_category_skill_mapping` (`category_id`,`skill_id`),
  ADD KEY `fk_category_skill_skill` (`skill_id`);

--
-- Indexes for table `duplicate_matches`
--
ALTER TABLE `duplicate_matches`
  ADD PRIMARY KEY (`duplicate_match_id`),
  ADD UNIQUE KEY `uq_duplicate_pair` (`source_ticket_id`,`matched_ticket_id`),
  ADD KEY `fk_duplicate_match` (`matched_ticket_id`),
  ADD KEY `fk_duplicate_reviewer` (`reviewed_by`),
  ADD KEY `idx_duplicate_review` (`match_status`,`created_at`),
  ADD KEY `idx_duplicate_source` (`source_ticket_id`);

--
-- Indexes for table `floors`
--
ALTER TABLE `floors`
  ADD PRIMARY KEY (`floor_id`),
  ADD UNIQUE KEY `uq_floor_number_per_building` (`building_id`,`floor_number`),
  ADD KEY `idx_floors_building_status` (`building_id`,`status`);

--
-- Indexes for table `issue_categories`
--
ALTER TABLE `issue_categories`
  ADD PRIMARY KEY (`category_id`),
  ADD UNIQUE KEY `uq_issue_category_code` (`category_code`),
  ADD UNIQUE KEY `uq_issue_category_name` (`name`),
  ADD KEY `fk_issue_category_skill` (`default_skill_id`),
  ADD KEY `idx_issue_categories_active` (`active`);

--
-- Indexes for table `login_attempts`
--
ALTER TABLE `login_attempts`
  ADD PRIMARY KEY (`login_attempt_id`),
  ADD KEY `idx_login_attempt_email_time` (`email_entered`,`attempted_at`),
  ADD KEY `idx_login_attempt_user_time` (`user_id`,`attempted_at`),
  ADD KEY `idx_login_attempt_success_time` (`was_successful`,`attempted_at`);

--
-- Indexes for table `maintenance_assets`
--
ALTER TABLE `maintenance_assets`
  ADD PRIMARY KEY (`asset_id`),
  ADD UNIQUE KEY `uq_asset_code` (`asset_code`),
  ADD KEY `fk_asset_floor` (`floor_id`),
  ADD KEY `fk_asset_area` (`area_id`),
  ADD KEY `fk_asset_unit` (`unit_id`),
  ADD KEY `idx_asset_location` (`building_id`,`floor_id`,`area_id`),
  ADD KEY `idx_asset_category` (`category_id`);

--
-- Indexes for table `maintenance_tickets`
--
ALTER TABLE `maintenance_tickets`
  ADD PRIMARY KEY (`ticket_id`),
  ADD UNIQUE KEY `uq_ticket_number` (`ticket_number`),
  ADD KEY `fk_ticket_floor` (`floor_id`),
  ADD KEY `fk_ticket_unit` (`unit_id`),
  ADD KEY `fk_ticket_area` (`area_id`),
  ADD KEY `fk_ticket_asset` (`asset_id`),
  ADD KEY `idx_ticket_resident_created` (`resident_id`,`created_at`),
  ADD KEY `idx_ticket_status_priority` (`current_status`,`current_priority`),
  ADD KEY `idx_ticket_risk` (`current_risk_level`,`current_risk_score`),
  ADD KEY `idx_ticket_category` (`current_category_id`),
  ADD KEY `idx_ticket_location` (`building_id`,`floor_id`,`area_id`),
  ADD KEY `idx_ticket_created` (`created_at`),
  ADD KEY `idx_stage5_ticket_reporting` (`building_id`,`current_status`,`current_priority`,`submitted_at`);
ALTER TABLE `maintenance_tickets` ADD FULLTEXT KEY `ft_ticket_text` (`subject`,`description`);

--
-- Indexes for table `model_versions`
--
ALTER TABLE `model_versions`
  ADD PRIMARY KEY (`model_version_id`),
  ADD UNIQUE KEY `uq_model_version` (`model_name`,`version`),
  ADD KEY `fk_model_version_created_by` (`created_by`),
  ADD KEY `idx_model_active` (`model_name`,`is_active`);

--
-- Indexes for table `notifications`
--
ALTER TABLE `notifications`
  ADD PRIMARY KEY (`notification_id`),
  ADD KEY `idx_notifications_user_read` (`user_id`,`read_at`,`created_at`),
  ADD KEY `idx_notifications_ticket` (`ticket_id`,`created_at`),
  ADD KEY `idx_notifications_delivery` (`delivery_status`,`channel`,`created_at`);

--
-- Indexes for table `notification_preferences`
--
ALTER TABLE `notification_preferences`
  ADD PRIMARY KEY (`notification_preference_id`),
  ADD UNIQUE KEY `uq_notification_preference_user` (`user_id`);

--
-- Indexes for table `notification_templates`
--
ALTER TABLE `notification_templates`
  ADD PRIMARY KEY (`notification_template_id`),
  ADD UNIQUE KEY `uq_notification_template` (`template_code`,`channel`);

--
-- Indexes for table `password_reset_tokens`
--
ALTER TABLE `password_reset_tokens`
  ADD PRIMARY KEY (`reset_token_id`),
  ADD UNIQUE KEY `uq_password_reset_token_hash` (`token_hash`),
  ADD KEY `idx_password_reset_expiry` (`user_id`,`expires_at`,`used_at`);

--
-- Indexes for table `permissions`
--
ALTER TABLE `permissions`
  ADD PRIMARY KEY (`permission_id`),
  ADD UNIQUE KEY `uq_permission_code` (`permission_code`);

--
-- Indexes for table `resident_profiles`
--
ALTER TABLE `resident_profiles`
  ADD PRIMARY KEY (`resident_id`),
  ADD UNIQUE KEY `uq_resident_profile_user` (`user_id`),
  ADD KEY `fk_resident_profile_floor` (`floor_id`),
  ADD KEY `fk_resident_profile_unit` (`unit_id`),
  ADD KEY `idx_resident_location` (`building_id`,`floor_id`,`unit_id`);

--
-- Indexes for table `resident_registration_requests`
--
ALTER TABLE `resident_registration_requests`
  ADD PRIMARY KEY (`request_id`),
  ADD UNIQUE KEY `uq_pending_registration_email` (`email`,`request_status`),
  ADD KEY `fk_registration_complex` (`complex_id`),
  ADD KEY `fk_registration_floor` (`floor_id`),
  ADD KEY `fk_registration_unit` (`unit_id`),
  ADD KEY `fk_registration_reviewer` (`reviewed_by`),
  ADD KEY `fk_registration_created_user` (`created_user_id`),
  ADD KEY `idx_registration_status_time` (`request_status`,`requested_at`),
  ADD KEY `idx_registration_building` (`building_id`,`request_status`);

--
-- Indexes for table `revoked_tokens`
--
ALTER TABLE `revoked_tokens`
  ADD PRIMARY KEY (`revoked_token_id`),
  ADD UNIQUE KEY `uq_revoked_token_jti` (`token_jti`),
  ADD KEY `fk_revoked_tokens_user` (`user_id`),
  ADD KEY `idx_revoked_token_expiry` (`expires_at`);

--
-- Indexes for table `roles`
--
ALTER TABLE `roles`
  ADD PRIMARY KEY (`role_id`),
  ADD UNIQUE KEY `uq_role_code` (`role_code`),
  ADD UNIQUE KEY `uq_role_name` (`role_name`);

--
-- Indexes for table `role_permissions`
--
ALTER TABLE `role_permissions`
  ADD PRIMARY KEY (`role_permission_id`),
  ADD UNIQUE KEY `uq_role_permission` (`role_id`,`permission_id`),
  ADD KEY `fk_role_permissions_permission` (`permission_id`);

--
-- Indexes for table `safety_rules`
--
ALTER TABLE `safety_rules`
  ADD PRIMARY KEY (`safety_rule_id`),
  ADD UNIQUE KEY `uq_safety_rule_code` (`rule_code`),
  ADD KEY `fk_safety_rule_category` (`category_id`),
  ADD KEY `fk_safety_rule_created_by` (`created_by`),
  ADD KEY `fk_safety_rule_updated_by` (`updated_by`),
  ADD KEY `idx_safety_rules_lookup` (`active`,`language_type`,`category_id`);

--
-- Indexes for table `skills`
--
ALTER TABLE `skills`
  ADD PRIMARY KEY (`skill_id`),
  ADD UNIQUE KEY `uq_skill_name` (`skill_name`);

--
-- Indexes for table `system_settings`
--
ALTER TABLE `system_settings`
  ADD PRIMARY KEY (`setting_id`),
  ADD UNIQUE KEY `uq_system_setting_key` (`setting_key`),
  ADD KEY `fk_system_setting_updated_by` (`updated_by`),
  ADD KEY `idx_system_setting_group` (`setting_group`);

--
-- Indexes for table `technician_profiles`
--
ALTER TABLE `technician_profiles`
  ADD PRIMARY KEY (`technician_id`),
  ADD UNIQUE KEY `uq_technician_profile_user` (`user_id`),
  ADD UNIQUE KEY `uq_technician_employee_code` (`employee_code`),
  ADD KEY `idx_technician_availability` (`availability`,`emergency_eligible`,`active`),
  ADD KEY `idx_technician_building` (`assigned_building_id`),
  ADD KEY `idx_technician_workload` (`current_workload`);

--
-- Indexes for table `technician_skills`
--
ALTER TABLE `technician_skills`
  ADD PRIMARY KEY (`technician_skill_id`),
  ADD UNIQUE KEY `uq_technician_skill` (`technician_id`,`skill_id`),
  ADD KEY `idx_technician_skill_lookup` (`skill_id`,`verified`,`is_primary`);

--
-- Indexes for table `temporary_passwords`
--
ALTER TABLE `temporary_passwords`
  ADD PRIMARY KEY (`temporary_password_id`),
  ADD UNIQUE KEY `uq_temp_password_user` (`user_id`),
  ADD KEY `fk_temp_password_created_by` (`created_by`),
  ADD KEY `idx_temp_password_active` (`user_id`,`used_at`,`expires_at`);

--
-- Indexes for table `ticket_assignments`
--
ALTER TABLE `ticket_assignments`
  ADD PRIMARY KEY (`assignment_id`),
  ADD KEY `fk_assignment_prediction` (`prediction_id`),
  ADD KEY `fk_assignment_assigned_by` (`assigned_by`),
  ADD KEY `idx_assignment_ticket_current` (`ticket_id`,`is_current`,`assigned_at`),
  ADD KEY `idx_assignment_technician_status` (`technician_id`,`assignment_status`,`is_current`),
  ADD KEY `idx_assignment_method` (`assignment_method`,`assigned_at`),
  ADD KEY `idx_stage5_assignment_reporting` (`technician_id`,`assignment_method`,`assignment_status`,`assigned_at`);

--
-- Indexes for table `ticket_attachments`
--
ALTER TABLE `ticket_attachments`
  ADD PRIMARY KEY (`attachment_id`),
  ADD KEY `fk_attachment_update` (`update_id`),
  ADD KEY `idx_attachment_ticket_type` (`ticket_id`,`attachment_type`),
  ADD KEY `idx_attachment_uploaded_by` (`uploaded_by`,`uploaded_at`);

--
-- Indexes for table `ticket_feedback`
--
ALTER TABLE `ticket_feedback`
  ADD PRIMARY KEY (`feedback_id`),
  ADD UNIQUE KEY `uq_ticket_feedback` (`ticket_id`),
  ADD KEY `fk_feedback_resident` (`resident_id`);

--
-- Indexes for table `ticket_status_transitions`
--
ALTER TABLE `ticket_status_transitions`
  ADD PRIMARY KEY (`transition_id`),
  ADD UNIQUE KEY `uq_ticket_status_transition` (`from_status`,`to_status`);

--
-- Indexes for table `ticket_updates`
--
ALTER TABLE `ticket_updates`
  ADD PRIMARY KEY (`update_id`),
  ADD KEY `idx_ticket_updates_timeline` (`ticket_id`,`created_at`),
  ADD KEY `idx_ticket_updates_user` (`updated_by`,`created_at`);

--
-- Indexes for table `units`
--
ALTER TABLE `units`
  ADD PRIMARY KEY (`unit_id`),
  ADD UNIQUE KEY `uq_unit_number_per_floor` (`floor_id`,`unit_number`),
  ADD KEY `idx_units_floor_status` (`floor_id`,`status`);

--
-- Indexes for table `users`
--
ALTER TABLE `users`
  ADD PRIMARY KEY (`user_id`),
  ADD UNIQUE KEY `uq_users_email` (`email`),
  ADD KEY `fk_users_created_by` (`created_by`),
  ADD KEY `idx_users_role_status` (`role_id`,`account_status`),
  ADD KEY `idx_users_complex` (`complex_id`),
  ADD KEY `idx_users_last_login` (`last_login_at`),
  ADD KEY `idx_users_deleted_status` (`is_deleted`,`account_status`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `ai_corrections`
--
ALTER TABLE `ai_corrections`
  MODIFY `correction_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ai_predictions`
--
ALTER TABLE `ai_predictions`
  MODIFY `prediction_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `apartment_admin_profiles`
--
ALTER TABLE `apartment_admin_profiles`
  MODIFY `admin_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=32;

--
-- AUTO_INCREMENT for table `apartment_complexes`
--
ALTER TABLE `apartment_complexes`
  MODIFY `complex_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `areas`
--
ALTER TABLE `areas`
  MODIFY `area_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `audit_logs`
--
ALTER TABLE `audit_logs`
  MODIFY `audit_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=1600;

--
-- AUTO_INCREMENT for table `backup_records`
--
ALTER TABLE `backup_records`
  MODIFY `backup_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `buildings`
--
ALTER TABLE `buildings`
  MODIFY `building_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=9;

--
-- AUTO_INCREMENT for table `category_skill_mappings`
--
ALTER TABLE `category_skill_mappings`
  MODIFY `category_skill_mapping_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `duplicate_matches`
--
ALTER TABLE `duplicate_matches`
  MODIFY `duplicate_match_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `floors`
--
ALTER TABLE `floors`
  MODIFY `floor_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=82;

--
-- AUTO_INCREMENT for table `issue_categories`
--
ALTER TABLE `issue_categories`
  MODIFY `category_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `login_attempts`
--
ALTER TABLE `login_attempts`
  MODIFY `login_attempt_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=533;

--
-- AUTO_INCREMENT for table `maintenance_assets`
--
ALTER TABLE `maintenance_assets`
  MODIFY `asset_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `maintenance_tickets`
--
ALTER TABLE `maintenance_tickets`
  MODIFY `ticket_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `model_versions`
--
ALTER TABLE `model_versions`
  MODIFY `model_version_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=35;

--
-- AUTO_INCREMENT for table `notifications`
--
ALTER TABLE `notifications`
  MODIFY `notification_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=339;

--
-- AUTO_INCREMENT for table `notification_preferences`
--
ALTER TABLE `notification_preferences`
  MODIFY `notification_preference_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=331;

--
-- AUTO_INCREMENT for table `notification_templates`
--
ALTER TABLE `notification_templates`
  MODIFY `notification_template_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=7;

--
-- AUTO_INCREMENT for table `password_reset_tokens`
--
ALTER TABLE `password_reset_tokens`
  MODIFY `reset_token_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT for table `permissions`
--
ALTER TABLE `permissions`
  MODIFY `permission_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=31;

--
-- AUTO_INCREMENT for table `resident_profiles`
--
ALTER TABLE `resident_profiles`
  MODIFY `resident_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=149;

--
-- AUTO_INCREMENT for table `resident_registration_requests`
--
ALTER TABLE `resident_registration_requests`
  MODIFY `request_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=33;

--
-- AUTO_INCREMENT for table `revoked_tokens`
--
ALTER TABLE `revoked_tokens`
  MODIFY `revoked_token_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=192;

--
-- AUTO_INCREMENT for table `roles`
--
ALTER TABLE `roles`
  MODIFY `role_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=5;

--
-- AUTO_INCREMENT for table `role_permissions`
--
ALTER TABLE `role_permissions`
  MODIFY `role_permission_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=44;

--
-- AUTO_INCREMENT for table `safety_rules`
--
ALTER TABLE `safety_rules`
  MODIFY `safety_rule_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `skills`
--
ALTER TABLE `skills`
  MODIFY `skill_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=13;

--
-- AUTO_INCREMENT for table `system_settings`
--
ALTER TABLE `system_settings`
  MODIFY `setting_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=32;

--
-- AUTO_INCREMENT for table `technician_profiles`
--
ALTER TABLE `technician_profiles`
  MODIFY `technician_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `technician_skills`
--
ALTER TABLE `technician_skills`
  MODIFY `technician_skill_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=232;

--
-- AUTO_INCREMENT for table `temporary_passwords`
--
ALTER TABLE `temporary_passwords`
  MODIFY `temporary_password_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT for table `ticket_assignments`
--
ALTER TABLE `ticket_assignments`
  MODIFY `assignment_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ticket_attachments`
--
ALTER TABLE `ticket_attachments`
  MODIFY `attachment_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=8;

--
-- AUTO_INCREMENT for table `ticket_feedback`
--
ALTER TABLE `ticket_feedback`
  MODIFY `feedback_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ticket_status_transitions`
--
ALTER TABLE `ticket_status_transitions`
  MODIFY `transition_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=36;

--
-- AUTO_INCREMENT for table `ticket_updates`
--
ALTER TABLE `ticket_updates`
  MODIFY `update_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=1036;

--
-- AUTO_INCREMENT for table `units`
--
ALTER TABLE `units`
  MODIFY `unit_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=90;

--
-- AUTO_INCREMENT for table `users`
--
ALTER TABLE `users`
  MODIFY `user_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=508;

--
-- Constraints for dumped tables
--

--
-- Constraints for table `ai_corrections`
--
ALTER TABLE `ai_corrections`
  ADD CONSTRAINT `fk_ai_correction_category` FOREIGN KEY (`corrected_category_id`) REFERENCES `issue_categories` (`category_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_ai_correction_prediction` FOREIGN KEY (`prediction_id`) REFERENCES `ai_predictions` (`prediction_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_ai_correction_skill` FOREIGN KEY (`corrected_skill_id`) REFERENCES `skills` (`skill_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_ai_correction_technician` FOREIGN KEY (`corrected_technician_id`) REFERENCES `technician_profiles` (`technician_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_ai_correction_user` FOREIGN KEY (`corrected_by`) REFERENCES `users` (`user_id`) ON UPDATE CASCADE;

--
-- Constraints for table `ai_predictions`
--
ALTER TABLE `ai_predictions`
  ADD CONSTRAINT `fk_prediction_category` FOREIGN KEY (`predicted_category_id`) REFERENCES `issue_categories` (`category_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_prediction_duplicate_ticket` FOREIGN KEY (`duplicate_ticket_id`) REFERENCES `maintenance_tickets` (`ticket_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_prediction_model` FOREIGN KEY (`model_version_id`) REFERENCES `model_versions` (`model_version_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_prediction_skill` FOREIGN KEY (`recommended_skill_id`) REFERENCES `skills` (`skill_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_prediction_technician` FOREIGN KEY (`recommended_technician_id`) REFERENCES `technician_profiles` (`technician_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_prediction_ticket` FOREIGN KEY (`ticket_id`) REFERENCES `maintenance_tickets` (`ticket_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `apartment_admin_profiles`
--
ALTER TABLE `apartment_admin_profiles`
  ADD CONSTRAINT `fk_admin_profile_building` FOREIGN KEY (`primary_building_id`) REFERENCES `buildings` (`building_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_admin_profile_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `areas`
--
ALTER TABLE `areas`
  ADD CONSTRAINT `fk_areas_building` FOREIGN KEY (`building_id`) REFERENCES `buildings` (`building_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_areas_floor` FOREIGN KEY (`floor_id`) REFERENCES `floors` (`floor_id`) ON UPDATE CASCADE;

--
-- Constraints for table `audit_logs`
--
ALTER TABLE `audit_logs`
  ADD CONSTRAINT `fk_audit_log_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE;

--
-- Constraints for table `backup_records`
--
ALTER TABLE `backup_records`
  ADD CONSTRAINT `fk_backup_restored_by` FOREIGN KEY (`restored_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_backup_started_by` FOREIGN KEY (`started_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE;

--
-- Constraints for table `buildings`
--
ALTER TABLE `buildings`
  ADD CONSTRAINT `fk_buildings_complex` FOREIGN KEY (`complex_id`) REFERENCES `apartment_complexes` (`complex_id`) ON UPDATE CASCADE;

--
-- Constraints for table `category_skill_mappings`
--
ALTER TABLE `category_skill_mappings`
  ADD CONSTRAINT `fk_category_skill_category` FOREIGN KEY (`category_id`) REFERENCES `issue_categories` (`category_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_category_skill_skill` FOREIGN KEY (`skill_id`) REFERENCES `skills` (`skill_id`) ON UPDATE CASCADE;

--
-- Constraints for table `duplicate_matches`
--
ALTER TABLE `duplicate_matches`
  ADD CONSTRAINT `fk_duplicate_match` FOREIGN KEY (`matched_ticket_id`) REFERENCES `maintenance_tickets` (`ticket_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_duplicate_reviewer` FOREIGN KEY (`reviewed_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_duplicate_source` FOREIGN KEY (`source_ticket_id`) REFERENCES `maintenance_tickets` (`ticket_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `floors`
--
ALTER TABLE `floors`
  ADD CONSTRAINT `fk_floors_building` FOREIGN KEY (`building_id`) REFERENCES `buildings` (`building_id`) ON UPDATE CASCADE;

--
-- Constraints for table `issue_categories`
--
ALTER TABLE `issue_categories`
  ADD CONSTRAINT `fk_issue_category_skill` FOREIGN KEY (`default_skill_id`) REFERENCES `skills` (`skill_id`) ON DELETE SET NULL ON UPDATE CASCADE;

--
-- Constraints for table `login_attempts`
--
ALTER TABLE `login_attempts`
  ADD CONSTRAINT `fk_login_attempt_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE;

--
-- Constraints for table `maintenance_assets`
--
ALTER TABLE `maintenance_assets`
  ADD CONSTRAINT `fk_asset_area` FOREIGN KEY (`area_id`) REFERENCES `areas` (`area_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_asset_building` FOREIGN KEY (`building_id`) REFERENCES `buildings` (`building_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_asset_category` FOREIGN KEY (`category_id`) REFERENCES `issue_categories` (`category_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_asset_floor` FOREIGN KEY (`floor_id`) REFERENCES `floors` (`floor_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_asset_unit` FOREIGN KEY (`unit_id`) REFERENCES `units` (`unit_id`) ON UPDATE CASCADE;

--
-- Constraints for table `maintenance_tickets`
--
ALTER TABLE `maintenance_tickets`
  ADD CONSTRAINT `fk_ticket_area` FOREIGN KEY (`area_id`) REFERENCES `areas` (`area_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_ticket_asset` FOREIGN KEY (`asset_id`) REFERENCES `maintenance_assets` (`asset_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_ticket_building` FOREIGN KEY (`building_id`) REFERENCES `buildings` (`building_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_ticket_current_category` FOREIGN KEY (`current_category_id`) REFERENCES `issue_categories` (`category_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_ticket_floor` FOREIGN KEY (`floor_id`) REFERENCES `floors` (`floor_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_ticket_resident` FOREIGN KEY (`resident_id`) REFERENCES `resident_profiles` (`resident_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_ticket_unit` FOREIGN KEY (`unit_id`) REFERENCES `units` (`unit_id`) ON UPDATE CASCADE;

--
-- Constraints for table `model_versions`
--
ALTER TABLE `model_versions`
  ADD CONSTRAINT `fk_model_version_created_by` FOREIGN KEY (`created_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE;

--
-- Constraints for table `notifications`
--
ALTER TABLE `notifications`
  ADD CONSTRAINT `fk_notification_ticket` FOREIGN KEY (`ticket_id`) REFERENCES `maintenance_tickets` (`ticket_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_notification_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `notification_preferences`
--
ALTER TABLE `notification_preferences`
  ADD CONSTRAINT `fk_notification_preference_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `password_reset_tokens`
--
ALTER TABLE `password_reset_tokens`
  ADD CONSTRAINT `fk_password_reset_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `resident_profiles`
--
ALTER TABLE `resident_profiles`
  ADD CONSTRAINT `fk_resident_profile_building` FOREIGN KEY (`building_id`) REFERENCES `buildings` (`building_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_resident_profile_floor` FOREIGN KEY (`floor_id`) REFERENCES `floors` (`floor_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_resident_profile_unit` FOREIGN KEY (`unit_id`) REFERENCES `units` (`unit_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_resident_profile_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `resident_registration_requests`
--
ALTER TABLE `resident_registration_requests`
  ADD CONSTRAINT `fk_registration_building` FOREIGN KEY (`building_id`) REFERENCES `buildings` (`building_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_registration_complex` FOREIGN KEY (`complex_id`) REFERENCES `apartment_complexes` (`complex_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_registration_created_user` FOREIGN KEY (`created_user_id`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_registration_floor` FOREIGN KEY (`floor_id`) REFERENCES `floors` (`floor_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_registration_reviewer` FOREIGN KEY (`reviewed_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_registration_unit` FOREIGN KEY (`unit_id`) REFERENCES `units` (`unit_id`) ON DELETE SET NULL ON UPDATE CASCADE;

--
-- Constraints for table `revoked_tokens`
--
ALTER TABLE `revoked_tokens`
  ADD CONSTRAINT `fk_revoked_tokens_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `role_permissions`
--
ALTER TABLE `role_permissions`
  ADD CONSTRAINT `fk_role_permissions_permission` FOREIGN KEY (`permission_id`) REFERENCES `permissions` (`permission_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_role_permissions_role` FOREIGN KEY (`role_id`) REFERENCES `roles` (`role_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `safety_rules`
--
ALTER TABLE `safety_rules`
  ADD CONSTRAINT `fk_safety_rule_category` FOREIGN KEY (`category_id`) REFERENCES `issue_categories` (`category_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_safety_rule_created_by` FOREIGN KEY (`created_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_safety_rule_updated_by` FOREIGN KEY (`updated_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE;

--
-- Constraints for table `system_settings`
--
ALTER TABLE `system_settings`
  ADD CONSTRAINT `fk_system_setting_updated_by` FOREIGN KEY (`updated_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE;

--
-- Constraints for table `technician_profiles`
--
ALTER TABLE `technician_profiles`
  ADD CONSTRAINT `fk_technician_profile_building` FOREIGN KEY (`assigned_building_id`) REFERENCES `buildings` (`building_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_technician_profile_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `technician_skills`
--
ALTER TABLE `technician_skills`
  ADD CONSTRAINT `fk_technician_skill_skill` FOREIGN KEY (`skill_id`) REFERENCES `skills` (`skill_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_technician_skill_technician` FOREIGN KEY (`technician_id`) REFERENCES `technician_profiles` (`technician_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `temporary_passwords`
--
ALTER TABLE `temporary_passwords`
  ADD CONSTRAINT `fk_temp_password_created_by` FOREIGN KEY (`created_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_temp_password_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `ticket_assignments`
--
ALTER TABLE `ticket_assignments`
  ADD CONSTRAINT `fk_assignment_assigned_by` FOREIGN KEY (`assigned_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_assignment_prediction` FOREIGN KEY (`prediction_id`) REFERENCES `ai_predictions` (`prediction_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_assignment_technician` FOREIGN KEY (`technician_id`) REFERENCES `technician_profiles` (`technician_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_assignment_ticket` FOREIGN KEY (`ticket_id`) REFERENCES `maintenance_tickets` (`ticket_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `ticket_attachments`
--
ALTER TABLE `ticket_attachments`
  ADD CONSTRAINT `fk_attachment_ticket` FOREIGN KEY (`ticket_id`) REFERENCES `maintenance_tickets` (`ticket_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_attachment_update` FOREIGN KEY (`update_id`) REFERENCES `ticket_updates` (`update_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_attachment_user` FOREIGN KEY (`uploaded_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE;

--
-- Constraints for table `ticket_feedback`
--
ALTER TABLE `ticket_feedback`
  ADD CONSTRAINT `fk_feedback_resident` FOREIGN KEY (`resident_id`) REFERENCES `resident_profiles` (`resident_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_feedback_ticket` FOREIGN KEY (`ticket_id`) REFERENCES `maintenance_tickets` (`ticket_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `ticket_updates`
--
ALTER TABLE `ticket_updates`
  ADD CONSTRAINT `fk_ticket_update_ticket` FOREIGN KEY (`ticket_id`) REFERENCES `maintenance_tickets` (`ticket_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_ticket_update_user` FOREIGN KEY (`updated_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE;

--
-- Constraints for table `units`
--
ALTER TABLE `units`
  ADD CONSTRAINT `fk_units_floor` FOREIGN KEY (`floor_id`) REFERENCES `floors` (`floor_id`) ON UPDATE CASCADE;

--
-- Constraints for table `users`
--
ALTER TABLE `users`
  ADD CONSTRAINT `fk_users_complex` FOREIGN KEY (`complex_id`) REFERENCES `apartment_complexes` (`complex_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_users_created_by` FOREIGN KEY (`created_by`) REFERENCES `users` (`user_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_users_role` FOREIGN KEY (`role_id`) REFERENCES `roles` (`role_id`) ON UPDATE CASCADE;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
