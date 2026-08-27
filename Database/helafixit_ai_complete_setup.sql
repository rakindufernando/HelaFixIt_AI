-- HelaFixIt AI final complete database setup
-- XAMPP / MariaDB compatible project database creation script.
-- Creates the current schema, database objects, reference configuration, complete apartment location data,
-- and the prepared Sri Lankan application users used by the system.
-- Run this file for a clean installation of the project database.


-- ============================================================================
-- 01_create_database.sql
-- ============================================================================
-- Create HelaFixIt AI database
-- MySQL 8.0 or later

DROP DATABASE IF EXISTS helafixit_ai;
CREATE DATABASE helafixit_ai
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
USE helafixit_ai;


-- ============================================================================
-- 02_schema.sql
-- ============================================================================
-- HelaFixIt AI MySQL database schema
-- Target MySQL 8.0 or later
-- Character set utf8mb4 supports English, Sinhala, Singlish and mixed text

USE helafixit_ai;

SET NAMES utf8mb4;
SET time_zone = '+05:30';

CREATE TABLE apartment_complexes (
    complex_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    address_line VARCHAR(255) NULL,
    city VARCHAR(100) NOT NULL DEFAULT 'Colombo',
    country VARCHAR(100) NOT NULL DEFAULT 'Sri Lanka',
    timezone_name VARCHAR(64) NOT NULL DEFAULT 'Asia/Colombo',
    status ENUM('Active','Inactive') NOT NULL DEFAULT 'Active',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_apartment_complex_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE roles (
    role_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    role_code VARCHAR(40) NOT NULL,
    role_name VARCHAR(80) NOT NULL,
    description VARCHAR(255) NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_role_code (role_code),
    UNIQUE KEY uq_role_name (role_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE permissions (
    permission_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    permission_code VARCHAR(100) NOT NULL,
    description VARCHAR(255) NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_permission_code (permission_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE role_permissions (
    role_permission_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    role_id BIGINT UNSIGNED NOT NULL,
    permission_id BIGINT UNSIGNED NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_role_permissions_role FOREIGN KEY (role_id) REFERENCES roles(role_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_role_permissions_permission FOREIGN KEY (permission_id) REFERENCES permissions(permission_id) ON UPDATE CASCADE ON DELETE CASCADE,
    UNIQUE KEY uq_role_permission (role_id, permission_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE buildings (
    building_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    complex_id BIGINT UNSIGNED NOT NULL,
    name VARCHAR(150) NOT NULL,
    block_code VARCHAR(50) NOT NULL,
    address_label VARCHAR(255) NULL,
    declared_floor_count SMALLINT UNSIGNED NULL,
    declared_unit_count SMALLINT UNSIGNED NULL,
    status ENUM('Active','Inactive') NOT NULL DEFAULT 'Active',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_buildings_complex FOREIGN KEY (complex_id) REFERENCES apartment_complexes(complex_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    UNIQUE KEY uq_building_code_per_complex (complex_id, block_code),
    KEY idx_buildings_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE floors (
    floor_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    building_id BIGINT UNSIGNED NOT NULL,
    floor_number SMALLINT NOT NULL,
    name VARCHAR(80) NOT NULL,
    status ENUM('Active','Inactive') NOT NULL DEFAULT 'Active',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_floors_building FOREIGN KEY (building_id) REFERENCES buildings(building_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    UNIQUE KEY uq_floor_number_per_building (building_id, floor_number),
    KEY idx_floors_building_status (building_id, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE units (
    unit_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    floor_id BIGINT UNSIGNED NOT NULL,
    unit_number VARCHAR(40) NOT NULL,
    unit_type ENUM('Apartment','Common Facility','Staff','Other') NOT NULL DEFAULT 'Apartment',
    status ENUM('Active','Inactive') NOT NULL DEFAULT 'Active',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_units_floor FOREIGN KEY (floor_id) REFERENCES floors(floor_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    UNIQUE KEY uq_unit_number_per_floor (floor_id, unit_number),
    KEY idx_units_floor_status (floor_id, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE areas (
    area_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    building_id BIGINT UNSIGNED NOT NULL,
    floor_id BIGINT UNSIGNED NULL,
    name VARCHAR(100) NOT NULL,
    area_type ENUM('Private','Common','Service','Outdoor','Other') NOT NULL DEFAULT 'Common',
    risk_weight DECIMAL(5,2) NOT NULL DEFAULT 0.00,
    status ENUM('Active','Inactive') NOT NULL DEFAULT 'Active',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_areas_building FOREIGN KEY (building_id) REFERENCES buildings(building_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_areas_floor FOREIGN KEY (floor_id) REFERENCES floors(floor_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_area_risk_weight CHECK (risk_weight BETWEEN 0 AND 30),
    UNIQUE KEY uq_area_location (building_id, floor_id, name),
    KEY idx_areas_building_floor (building_id, floor_id),
    KEY idx_areas_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE users (
    user_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    role_id BIGINT UNSIGNED NOT NULL,
    complex_id BIGINT UNSIGNED NOT NULL,
    full_name VARCHAR(150) NOT NULL,
    email VARCHAR(190) NOT NULL,
    phone VARCHAR(30) NULL,
    password_hash VARCHAR(255) NOT NULL,
    account_status ENUM('Pending','Active','Suspended','Disabled','Locked') NOT NULL DEFAULT 'Pending',
    email_verified BOOLEAN NOT NULL DEFAULT FALSE,
    failed_login_count SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    locked_until DATETIME NULL,
    last_login_at DATETIME NULL,
    last_password_change_at DATETIME NULL,
    must_change_password BOOLEAN NOT NULL DEFAULT FALSE,
    auth_version SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at DATETIME NULL,
    created_by BIGINT UNSIGNED NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_users_role FOREIGN KEY (role_id) REFERENCES roles(role_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_users_complex FOREIGN KEY (complex_id) REFERENCES apartment_complexes(complex_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_users_created_by FOREIGN KEY (created_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    UNIQUE KEY uq_users_email (email),
    KEY idx_users_role_status (role_id, account_status),
    KEY idx_users_complex (complex_id),
    KEY idx_users_last_login (last_login_at),
    KEY idx_users_deleted_status (is_deleted, account_status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE resident_registration_requests (
    request_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    full_name VARCHAR(150) NOT NULL,
    email VARCHAR(190) NOT NULL,
    phone VARCHAR(30) NOT NULL,
    complex_id BIGINT UNSIGNED NOT NULL,
    building_id BIGINT UNSIGNED NOT NULL,
    floor_id BIGINT UNSIGNED NOT NULL,
    unit_id BIGINT UNSIGNED NULL,
    unit_number VARCHAR(40) NULL,
    resident_type ENUM('Owner','Tenant','Family','Other') NOT NULL DEFAULT 'Other',
    preferred_language ENUM('English','Sinhala','Singlish','Mixed') NOT NULL DEFAULT 'English',
    contact_preference ENUM('In App','Email','SMS','Phone') NOT NULL DEFAULT 'In App',
    password_hash VARCHAR(255) NOT NULL,
    request_status ENUM('Pending','Approved','Rejected','Cancelled') NOT NULL DEFAULT 'Pending',
    requested_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reviewed_by BIGINT UNSIGNED NULL,
    reviewed_at DATETIME NULL,
    review_note VARCHAR(1000) NULL,
    created_user_id BIGINT UNSIGNED NULL,
    source_ip VARCHAR(45) NULL,
    user_agent VARCHAR(500) NULL,
    CONSTRAINT fk_registration_complex FOREIGN KEY (complex_id) REFERENCES apartment_complexes(complex_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_registration_building FOREIGN KEY (building_id) REFERENCES buildings(building_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_registration_floor FOREIGN KEY (floor_id) REFERENCES floors(floor_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_registration_unit FOREIGN KEY (unit_id) REFERENCES units(unit_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_registration_reviewer FOREIGN KEY (reviewed_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_registration_created_user FOREIGN KEY (created_user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    UNIQUE KEY uq_pending_registration_email (email, request_status),
    KEY idx_registration_status_time (request_status, requested_at),
    KEY idx_registration_building (building_id, request_status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE password_reset_tokens (
    reset_token_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    token_hash CHAR(64) NOT NULL,
    expires_at DATETIME NOT NULL,
    used_at DATETIME NULL,
    requested_ip VARCHAR(45) NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_password_reset_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE,
    UNIQUE KEY uq_password_reset_token_hash (token_hash),
    KEY idx_password_reset_expiry (user_id, expires_at, used_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE revoked_tokens (
    revoked_token_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    token_jti VARCHAR(120) NOT NULL,
    token_type ENUM('Access','Refresh') NOT NULL,
    expires_at DATETIME NOT NULL,
    revoked_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reason VARCHAR(255) NULL,
    CONSTRAINT fk_revoked_tokens_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE,
    UNIQUE KEY uq_revoked_token_jti (token_jti),
    KEY idx_revoked_token_expiry (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE login_attempts (
    login_attempt_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NULL,
    email_entered VARCHAR(190) NULL,
    was_successful BOOLEAN NOT NULL,
    ip_address VARCHAR(45) NULL,
    user_agent VARCHAR(500) NULL,
    failure_reason VARCHAR(255) NULL,
    attempted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_login_attempt_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    KEY idx_login_attempt_email_time (email_entered, attempted_at),
    KEY idx_login_attempt_user_time (user_id, attempted_at),
    KEY idx_login_attempt_success_time (was_successful, attempted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE resident_profiles (
    resident_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    building_id BIGINT UNSIGNED NOT NULL,
    floor_id BIGINT UNSIGNED NOT NULL,
    unit_id BIGINT UNSIGNED NULL,
    unit_number VARCHAR(40) NULL,
    resident_type ENUM('Owner','Tenant','Family','Other') NOT NULL DEFAULT 'Other',
    preferred_language ENUM('English','Sinhala','Singlish','Mixed') NOT NULL DEFAULT 'English',
    contact_preference ENUM('In App','Email','SMS','Phone') NOT NULL DEFAULT 'In App',
    profile_status ENUM('Active','Inactive') NOT NULL DEFAULT 'Active',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_resident_profile_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_resident_profile_building FOREIGN KEY (building_id) REFERENCES buildings(building_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_resident_profile_floor FOREIGN KEY (floor_id) REFERENCES floors(floor_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_resident_profile_unit FOREIGN KEY (unit_id) REFERENCES units(unit_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    UNIQUE KEY uq_resident_profile_user (user_id),
    KEY idx_resident_location (building_id, floor_id, unit_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE apartment_admin_profiles (
    admin_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    primary_building_id BIGINT UNSIGNED NULL,
    job_title VARCHAR(100) NULL,
    can_review_emergencies BOOLEAN NOT NULL DEFAULT TRUE,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_admin_profile_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_admin_profile_building FOREIGN KEY (primary_building_id) REFERENCES buildings(building_id) ON UPDATE CASCADE ON DELETE SET NULL,
    UNIQUE KEY uq_admin_profile_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE skills (
    skill_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    skill_name VARCHAR(100) NOT NULL,
    description VARCHAR(255) NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_skill_name (skill_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE technician_profiles (
    technician_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    employee_code VARCHAR(50) NOT NULL,
    assigned_building_id BIGINT UNSIGNED NULL,
    availability ENUM('Available','Busy','Off Duty','On Leave') NOT NULL DEFAULT 'Off Duty',
    current_workload SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    max_active_jobs SMALLINT UNSIGNED NOT NULL DEFAULT 4,
    emergency_eligible BOOLEAN NOT NULL DEFAULT FALSE,
    can_work_after_hours BOOLEAN NOT NULL DEFAULT FALSE,
    service_area VARCHAR(150) NULL,
    years_experience DECIMAL(4,1) NULL,
    average_response_minutes SMALLINT UNSIGNED NULL,
    special_equipment_notes VARCHAR(255) NULL,
    rating DECIMAL(3,2) NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    last_availability_change_at DATETIME NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_technician_profile_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_technician_profile_building FOREIGN KEY (assigned_building_id) REFERENCES buildings(building_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT chk_technician_rating CHECK (rating IS NULL OR (rating BETWEEN 0 AND 5)),
    CONSTRAINT chk_technician_workload_limit CHECK (current_workload <= 100 AND max_active_jobs BETWEEN 1 AND 100),
    UNIQUE KEY uq_technician_profile_user (user_id),
    UNIQUE KEY uq_technician_employee_code (employee_code),
    KEY idx_technician_availability (availability, emergency_eligible, active),
    KEY idx_technician_building (assigned_building_id),
    KEY idx_technician_workload (current_workload)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE technician_skills (
    technician_skill_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    technician_id BIGINT UNSIGNED NOT NULL,
    skill_id BIGINT UNSIGNED NOT NULL,
    skill_level ENUM('Basic','Intermediate','Advanced','Expert') NOT NULL DEFAULT 'Intermediate',
    verified BOOLEAN NOT NULL DEFAULT FALSE,
    experience_years DECIMAL(4,1) NULL,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_technician_skill_technician FOREIGN KEY (technician_id) REFERENCES technician_profiles(technician_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_technician_skill_skill FOREIGN KEY (skill_id) REFERENCES skills(skill_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    UNIQUE KEY uq_technician_skill (technician_id, skill_id),
    KEY idx_technician_skill_lookup (skill_id, verified, is_primary)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE issue_categories (
    category_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    category_code VARCHAR(50) NOT NULL,
    name VARCHAR(100) NOT NULL,
    default_skill_id BIGINT UNSIGNED NULL,
    default_priority ENUM('Emergency','High','Medium','Low') NOT NULL DEFAULT 'Medium',
    severity_weight DECIMAL(5,2) NOT NULL DEFAULT 0.00,
    description VARCHAR(255) NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_issue_category_skill FOREIGN KEY (default_skill_id) REFERENCES skills(skill_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT chk_category_severity_weight CHECK (severity_weight BETWEEN 0 AND 30),
    UNIQUE KEY uq_issue_category_code (category_code),
    UNIQUE KEY uq_issue_category_name (name),
    KEY idx_issue_categories_active (active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE category_skill_mappings (
    category_skill_mapping_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    category_id BIGINT UNSIGNED NOT NULL,
    skill_id BIGINT UNSIGNED NOT NULL,
    required_level ENUM('Basic','Intermediate','Advanced','Expert') NOT NULL DEFAULT 'Intermediate',
    match_weight DECIMAL(5,2) NOT NULL DEFAULT 100.00,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT fk_category_skill_category FOREIGN KEY (category_id) REFERENCES issue_categories(category_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_category_skill_skill FOREIGN KEY (skill_id) REFERENCES skills(skill_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_category_skill_weight CHECK (match_weight BETWEEN 0 AND 100),
    UNIQUE KEY uq_category_skill_mapping (category_id, skill_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE safety_rules (
    safety_rule_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    category_id BIGINT UNSIGNED NULL,
    rule_code VARCHAR(80) NOT NULL,
    keyword_or_pattern VARCHAR(255) NOT NULL,
    match_type ENUM('Keyword','Phrase','Regex') NOT NULL DEFAULT 'Keyword',
    language_type ENUM('English','Sinhala','Singlish','Mixed','Any') NOT NULL DEFAULT 'Any',
    score_weight DECIMAL(5,2) NOT NULL,
    severity ENUM('Low','Medium','High','Critical') NOT NULL,
    warning_message VARCHAR(500) NOT NULL,
    resident_action VARCHAR(500) NULL,
    technician_action VARCHAR(500) NULL,
    rule_version VARCHAR(40) NOT NULL DEFAULT '1.0.0',
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_by BIGINT UNSIGNED NULL,
    updated_by BIGINT UNSIGNED NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_safety_rule_category FOREIGN KEY (category_id) REFERENCES issue_categories(category_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_safety_rule_created_by FOREIGN KEY (created_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_safety_rule_updated_by FOREIGN KEY (updated_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT chk_safety_rule_weight CHECK (score_weight BETWEEN 0 AND 50),
    UNIQUE KEY uq_safety_rule_code (rule_code),
    KEY idx_safety_rules_lookup (active, language_type, category_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE model_versions (
    model_version_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    model_name VARCHAR(120) NOT NULL,
    version VARCHAR(40) NOT NULL,
    artifact_path VARCHAR(500) NULL,
    metrics_json JSON NULL,
    label_mapping_json JSON NULL,
    training_data_version VARCHAR(80) NULL,
    notes VARCHAR(500) NULL,
    is_active BOOLEAN NOT NULL DEFAULT FALSE,
    created_by BIGINT UNSIGNED NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_model_version_created_by FOREIGN KEY (created_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    UNIQUE KEY uq_model_version (model_name, version),
    KEY idx_model_active (model_name, is_active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE maintenance_assets (
    asset_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    building_id BIGINT UNSIGNED NOT NULL,
    floor_id BIGINT UNSIGNED NULL,
    area_id BIGINT UNSIGNED NULL,
    unit_id BIGINT UNSIGNED NULL,
    category_id BIGINT UNSIGNED NULL,
    asset_code VARCHAR(80) NOT NULL,
    asset_type VARCHAR(100) NOT NULL,
    name VARCHAR(150) NOT NULL,
    status ENUM('Active','Out of Service','Retired') NOT NULL DEFAULT 'Active',
    notes VARCHAR(500) NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_asset_building FOREIGN KEY (building_id) REFERENCES buildings(building_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_asset_floor FOREIGN KEY (floor_id) REFERENCES floors(floor_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_asset_area FOREIGN KEY (area_id) REFERENCES areas(area_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_asset_unit FOREIGN KEY (unit_id) REFERENCES units(unit_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_asset_category FOREIGN KEY (category_id) REFERENCES issue_categories(category_id) ON UPDATE CASCADE ON DELETE SET NULL,
    UNIQUE KEY uq_asset_code (asset_code),
    KEY idx_asset_location (building_id, floor_id, area_id),
    KEY idx_asset_category (category_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE maintenance_tickets (
    ticket_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    ticket_number VARCHAR(40) NOT NULL,
    resident_id BIGINT UNSIGNED NOT NULL,
    building_id BIGINT UNSIGNED NOT NULL,
    floor_id BIGINT UNSIGNED NOT NULL,
    unit_id BIGINT UNSIGNED NULL,
    area_id BIGINT UNSIGNED NULL,
    asset_id BIGINT UNSIGNED NULL,
    unit_number_snapshot VARCHAR(40) NULL,
    subject VARCHAR(180) NOT NULL,
    description LONGTEXT NOT NULL,
    language_type ENUM('English','Sinhala','Singlish','Mixed','Unknown') NOT NULL DEFAULT 'Unknown',
    asset_type VARCHAR(100) NULL,
    contact_permission BOOLEAN NOT NULL DEFAULT FALSE,
    current_category_id BIGINT UNSIGNED NULL,
    current_priority ENUM('Emergency','High','Medium','Low') NULL,
    current_risk_score DECIMAL(5,2) NULL,
    current_risk_level ENUM('Low','Medium','High','Critical') NULL,
    current_status ENUM('Submitted','Analysing','Awaiting Review','Urgent Unassigned','Auto Assigned','Assigned','Accepted','In Progress','On Hold','Resolved','Closed','Reopened','Cancelled') NOT NULL DEFAULT 'Submitted',
    safety_flag BOOLEAN NOT NULL DEFAULT FALSE,
    duplicate_flag BOOLEAN NOT NULL DEFAULT FALSE,
    manual_review_required BOOLEAN NOT NULL DEFAULT FALSE,
    submitted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    analysed_at DATETIME NULL,
    resolved_at DATETIME NULL,
    closed_at DATETIME NULL,
    cancelled_at DATETIME NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_ticket_resident FOREIGN KEY (resident_id) REFERENCES resident_profiles(resident_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ticket_building FOREIGN KEY (building_id) REFERENCES buildings(building_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ticket_floor FOREIGN KEY (floor_id) REFERENCES floors(floor_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ticket_unit FOREIGN KEY (unit_id) REFERENCES units(unit_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ticket_area FOREIGN KEY (area_id) REFERENCES areas(area_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ticket_asset FOREIGN KEY (asset_id) REFERENCES maintenance_assets(asset_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_ticket_current_category FOREIGN KEY (current_category_id) REFERENCES issue_categories(category_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT chk_ticket_risk_score CHECK (current_risk_score IS NULL OR current_risk_score BETWEEN 0 AND 100),
    UNIQUE KEY uq_ticket_number (ticket_number),
    KEY idx_ticket_resident_created (resident_id, created_at),
    KEY idx_ticket_status_priority (current_status, current_priority),
    KEY idx_ticket_risk (current_risk_level, current_risk_score),
    KEY idx_ticket_category (current_category_id),
    KEY idx_ticket_location (building_id, floor_id, area_id),
    KEY idx_ticket_created (created_at),
    FULLTEXT KEY ft_ticket_text (subject, description)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE ticket_status_transitions (
    transition_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    from_status VARCHAR(30) NOT NULL,
    to_status VARCHAR(30) NOT NULL,
    requires_note BOOLEAN NOT NULL DEFAULT FALSE,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    description VARCHAR(255) NULL,
    UNIQUE KEY uq_ticket_status_transition (from_status, to_status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE ticket_updates (
    update_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    ticket_id BIGINT UNSIGNED NOT NULL,
    updated_by BIGINT UNSIGNED NULL,
    update_type ENUM('System Event','Status Update','Repair Note','Admin Note','Resident Note','Completion Note','Reopen Note','Cancellation Note') NOT NULL DEFAULT 'System Event',
    status_from VARCHAR(30) NULL,
    status_to VARCHAR(30) NULL,
    note TEXT NULL,
    parts_used JSON NULL,
    resident_visible BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_ticket_update_ticket FOREIGN KEY (ticket_id) REFERENCES maintenance_tickets(ticket_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_ticket_update_user FOREIGN KEY (updated_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    KEY idx_ticket_updates_timeline (ticket_id, created_at),
    KEY idx_ticket_updates_user (updated_by, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE ticket_attachments (
    attachment_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    ticket_id BIGINT UNSIGNED NOT NULL,
    update_id BIGINT UNSIGNED NULL,
    uploaded_by BIGINT UNSIGNED NULL,
    attachment_type ENUM('Issue Photo','Progress Photo','Completion Proof','Document','Other') NOT NULL DEFAULT 'Other',
    original_file_name VARCHAR(255) NOT NULL,
    stored_file_name VARCHAR(255) NOT NULL,
    storage_path VARCHAR(500) NOT NULL,
    mime_type VARCHAR(100) NOT NULL,
    file_size_bytes BIGINT UNSIGNED NOT NULL,
    checksum_sha256 CHAR(64) NULL,
    resident_visible BOOLEAN NOT NULL DEFAULT TRUE,
    uploaded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at DATETIME NULL,
    CONSTRAINT fk_attachment_ticket FOREIGN KEY (ticket_id) REFERENCES maintenance_tickets(ticket_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_attachment_update FOREIGN KEY (update_id) REFERENCES ticket_updates(update_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_attachment_user FOREIGN KEY (uploaded_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    KEY idx_attachment_ticket_type (ticket_id, attachment_type),
    KEY idx_attachment_uploaded_by (uploaded_by, uploaded_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE ai_predictions (
    prediction_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    ticket_id BIGINT UNSIGNED NOT NULL,
    model_version_id BIGINT UNSIGNED NULL,
    predicted_category_id BIGINT UNSIGNED NULL,
    category_confidence DECIMAL(6,5) NULL,
    predicted_priority ENUM('Emergency','High','Medium','Low') NOT NULL,
    priority_confidence DECIMAL(6,5) NULL,
    risk_score DECIMAL(5,2) NOT NULL,
    risk_level ENUM('Low','Medium','High','Critical') NOT NULL,
    risk_factors JSON NULL,
    safety_flag BOOLEAN NOT NULL DEFAULT FALSE,
    safety_warning VARCHAR(1000) NULL,
    safety_trigger_codes JSON NULL,
    duplicate_flag BOOLEAN NOT NULL DEFAULT FALSE,
    duplicate_ticket_id BIGINT UNSIGNED NULL,
    duplicate_similarity DECIMAL(6,5) NULL,
    recommended_skill_id BIGINT UNSIGNED NULL,
    recommended_technician_id BIGINT UNSIGNED NULL,
    technician_score DECIMAL(5,2) NULL,
    auto_assignment_required BOOLEAN NOT NULL DEFAULT FALSE,
    manual_review_required BOOLEAN NOT NULL DEFAULT FALSE,
    review_status ENUM('Pending','Accepted','Corrected','Rejected','Auto Accepted') NOT NULL DEFAULT 'Pending',
    is_current BOOLEAN NOT NULL DEFAULT TRUE,
    rule_version VARCHAR(40) NOT NULL DEFAULT '1.0.0',
    processing_time_ms INT UNSIGNED NULL,
    processed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_prediction_ticket FOREIGN KEY (ticket_id) REFERENCES maintenance_tickets(ticket_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_prediction_model FOREIGN KEY (model_version_id) REFERENCES model_versions(model_version_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_prediction_category FOREIGN KEY (predicted_category_id) REFERENCES issue_categories(category_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_prediction_duplicate_ticket FOREIGN KEY (duplicate_ticket_id) REFERENCES maintenance_tickets(ticket_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_prediction_skill FOREIGN KEY (recommended_skill_id) REFERENCES skills(skill_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_prediction_technician FOREIGN KEY (recommended_technician_id) REFERENCES technician_profiles(technician_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT chk_category_confidence CHECK (category_confidence IS NULL OR category_confidence BETWEEN 0 AND 1),
    CONSTRAINT chk_priority_confidence CHECK (priority_confidence IS NULL OR priority_confidence BETWEEN 0 AND 1),
    CONSTRAINT chk_prediction_risk CHECK (risk_score BETWEEN 0 AND 100),
    CONSTRAINT chk_duplicate_similarity CHECK (duplicate_similarity IS NULL OR duplicate_similarity BETWEEN 0 AND 1),
    CONSTRAINT chk_technician_score CHECK (technician_score IS NULL OR technician_score BETWEEN 0 AND 100),
    KEY idx_predictions_ticket_current (ticket_id, is_current, processed_at),
    KEY idx_predictions_review (review_status, manual_review_required, processed_at),
    KEY idx_predictions_priority_risk (predicted_priority, risk_level),
    KEY idx_predictions_model (model_version_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE ai_corrections (
    correction_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    prediction_id BIGINT UNSIGNED NOT NULL,
    corrected_by BIGINT UNSIGNED NOT NULL,
    corrected_category_id BIGINT UNSIGNED NULL,
    corrected_priority ENUM('Emergency','High','Medium','Low') NULL,
    corrected_risk_score DECIMAL(5,2) NULL,
    corrected_risk_level ENUM('Low','Medium','High','Critical') NULL,
    corrected_skill_id BIGINT UNSIGNED NULL,
    corrected_technician_id BIGINT UNSIGNED NULL,
    reason VARCHAR(1000) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_ai_correction_prediction FOREIGN KEY (prediction_id) REFERENCES ai_predictions(prediction_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_ai_correction_user FOREIGN KEY (corrected_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_ai_correction_category FOREIGN KEY (corrected_category_id) REFERENCES issue_categories(category_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_ai_correction_skill FOREIGN KEY (corrected_skill_id) REFERENCES skills(skill_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_ai_correction_technician FOREIGN KEY (corrected_technician_id) REFERENCES technician_profiles(technician_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT chk_ai_correction_risk CHECK (corrected_risk_score IS NULL OR corrected_risk_score BETWEEN 0 AND 100),
    KEY idx_ai_corrections_prediction (prediction_id, created_at),
    KEY idx_ai_corrections_user (corrected_by, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE duplicate_matches (
    duplicate_match_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    source_ticket_id BIGINT UNSIGNED NOT NULL,
    matched_ticket_id BIGINT UNSIGNED NOT NULL,
    similarity_score DECIMAL(6,5) NOT NULL,
    location_match_score DECIMAL(6,5) NULL,
    match_status ENUM('Pending','Confirmed','Rejected','Linked') NOT NULL DEFAULT 'Pending',
    reviewed_by BIGINT UNSIGNED NULL,
    review_notes VARCHAR(1000) NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reviewed_at DATETIME NULL,
    CONSTRAINT fk_duplicate_source FOREIGN KEY (source_ticket_id) REFERENCES maintenance_tickets(ticket_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_duplicate_match FOREIGN KEY (matched_ticket_id) REFERENCES maintenance_tickets(ticket_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_duplicate_reviewer FOREIGN KEY (reviewed_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT chk_duplicate_distinct_tickets CHECK (source_ticket_id <> matched_ticket_id),
    CONSTRAINT chk_duplicate_score CHECK (similarity_score BETWEEN 0 AND 1),
    CONSTRAINT chk_location_match_score CHECK (location_match_score IS NULL OR location_match_score BETWEEN 0 AND 1),
    UNIQUE KEY uq_duplicate_pair (source_ticket_id, matched_ticket_id),
    KEY idx_duplicate_review (match_status, created_at),
    KEY idx_duplicate_source (source_ticket_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE ticket_assignments (
    assignment_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    ticket_id BIGINT UNSIGNED NOT NULL,
    technician_id BIGINT UNSIGNED NOT NULL,
    prediction_id BIGINT UNSIGNED NULL,
    assignment_method ENUM('Manual','Auto Emergency','Reassignment') NOT NULL,
    assigned_by BIGINT UNSIGNED NULL,
    assigned_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    accepted_at DATETIME NULL,
    declined_at DATETIME NULL,
    started_at DATETIME NULL,
    completed_at DATETIME NULL,
    assignment_status ENUM('Assigned','Accepted','Declined','In Progress','On Hold','Completed','Cancelled','Reassigned') NOT NULL DEFAULT 'Assigned',
    assignment_score DECIMAL(5,2) NULL,
    assignment_reason VARCHAR(1000) NULL,
    decline_reason VARCHAR(1000) NULL,
    admin_override BOOLEAN NOT NULL DEFAULT FALSE,
    override_reason VARCHAR(1000) NULL,
    is_current BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_assignment_ticket FOREIGN KEY (ticket_id) REFERENCES maintenance_tickets(ticket_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_assignment_technician FOREIGN KEY (technician_id) REFERENCES technician_profiles(technician_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_assignment_prediction FOREIGN KEY (prediction_id) REFERENCES ai_predictions(prediction_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_assignment_assigned_by FOREIGN KEY (assigned_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT chk_assignment_score CHECK (assignment_score IS NULL OR assignment_score BETWEEN 0 AND 100),
    KEY idx_assignment_ticket_current (ticket_id, is_current, assigned_at),
    KEY idx_assignment_technician_status (technician_id, assignment_status, is_current),
    KEY idx_assignment_method (assignment_method, assigned_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE ticket_feedback (
    feedback_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    ticket_id BIGINT UNSIGNED NOT NULL,
    resident_id BIGINT UNSIGNED NOT NULL,
    resolution_confirmed BOOLEAN NOT NULL DEFAULT TRUE,
    rating TINYINT UNSIGNED NULL,
    comment VARCHAR(1000) NULL,
    reopened_after_feedback BOOLEAN NOT NULL DEFAULT FALSE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_feedback_ticket FOREIGN KEY (ticket_id) REFERENCES maintenance_tickets(ticket_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_feedback_resident FOREIGN KEY (resident_id) REFERENCES resident_profiles(resident_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_feedback_rating CHECK (rating IS NULL OR rating BETWEEN 1 AND 5),
    UNIQUE KEY uq_ticket_feedback (ticket_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE notification_preferences (
    notification_preference_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    in_app_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    email_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    sms_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    browser_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    emergency_sms_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    ticket_status_updates_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_notification_preference_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE,
    UNIQUE KEY uq_notification_preference_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE notification_templates (
    notification_template_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    template_code VARCHAR(80) NOT NULL,
    event_type VARCHAR(80) NOT NULL,
    channel ENUM('In App','Email','SMS','Push','WhatsApp') NOT NULL,
    subject_template VARCHAR(255) NULL,
    message_template TEXT NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_notification_template (template_code, channel)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE notifications (
    notification_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    ticket_id BIGINT UNSIGNED NULL,
    event_type VARCHAR(80) NOT NULL,
    channel ENUM('In App','Email','SMS','Push','WhatsApp') NOT NULL DEFAULT 'In App',
    title VARCHAR(180) NOT NULL,
    message VARCHAR(1000) NOT NULL,
    delivery_status ENUM('Queued','Sent','Delivered','Failed','Read','Skipped') NOT NULL DEFAULT 'Queued',
    provider_reference VARCHAR(255) NULL,
    retry_count SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sent_at DATETIME NULL,
    delivered_at DATETIME NULL,
    read_at DATETIME NULL,
    CONSTRAINT fk_notification_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_notification_ticket FOREIGN KEY (ticket_id) REFERENCES maintenance_tickets(ticket_id) ON UPDATE CASCADE ON DELETE CASCADE,
    KEY idx_notifications_user_read (user_id, read_at, created_at),
    KEY idx_notifications_ticket (ticket_id, created_at),
    KEY idx_notifications_delivery (delivery_status, channel, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE system_settings (
    setting_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    setting_key VARCHAR(120) NOT NULL,
    setting_value TEXT NOT NULL,
    value_type ENUM('String','Integer','Decimal','Boolean','JSON') NOT NULL DEFAULT 'String',
    setting_group VARCHAR(80) NOT NULL DEFAULT 'General',
    description VARCHAR(500) NULL,
    updated_by BIGINT UNSIGNED NULL,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_system_setting_updated_by FOREIGN KEY (updated_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    UNIQUE KEY uq_system_setting_key (setting_key),
    KEY idx_system_setting_group (setting_group)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE audit_logs (
    audit_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NULL,
    action_type VARCHAR(100) NOT NULL,
    entity_type VARCHAR(80) NOT NULL,
    entity_id VARCHAR(80) NULL,
    old_value JSON NULL,
    new_value JSON NULL,
    reason VARCHAR(1000) NULL,
    ip_address VARCHAR(45) NULL,
    user_agent VARCHAR(500) NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_audit_log_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    KEY idx_audit_entity (entity_type, entity_id, created_at),
    KEY idx_audit_user (user_id, created_at),
    KEY idx_audit_action (action_type, created_at),
    KEY idx_audit_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE backup_records (
    backup_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    started_by BIGINT UNSIGNED NULL,
    backup_type ENUM('Manual','Automatic','Full','Schema','Data') NOT NULL DEFAULT 'Manual',
    file_name VARCHAR(255) NULL,
    file_location VARCHAR(500) NULL,
    backup_status ENUM('Started','Completed','Failed','Restored') NOT NULL DEFAULT 'Started',
    size_bytes BIGINT UNSIGNED NULL,
    checksum_sha256 CHAR(64) NULL,
    started_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at DATETIME NULL,
    restored_at DATETIME NULL,
    restored_by BIGINT UNSIGNED NULL,
    notes VARCHAR(1000) NULL,
    CONSTRAINT fk_backup_started_by FOREIGN KEY (started_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_backup_restored_by FOREIGN KEY (restored_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    KEY idx_backup_status_time (backup_status, started_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- 03_triggers.sql
-- ============================================================================
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


-- ============================================================================
-- 04_views.sql
-- ============================================================================
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


-- ============================================================================
-- 05_stored_procedures.sql
-- ============================================================================
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


-- ============================================================================
-- 06_seed_reference_data.sql
-- ============================================================================
-- HelaFixIt AI reference and configuration data
USE helafixit_ai;
SET NAMES utf8mb4;

INSERT INTO apartment_complexes(complex_id, name, city, country, timezone_name, status)
VALUES(1, 'HelaFixIt Apartment Complex', 'Colombo', 'Sri Lanka', 'Asia/Colombo', 'Active');

INSERT INTO roles(role_id, role_code, role_name, description, active) VALUES
(1, 'resident', 'Resident', 'Submit and track own maintenance tickets', TRUE),
(2, 'apartment_admin', 'Apartment Admin', 'Manage maintenance workflow, resident approvals and AI review', TRUE),
(3, 'technician', 'Technician', 'Handle assigned maintenance jobs and repair updates', TRUE),
(4, 'system_admin', 'System Admin', 'Manage users, configuration, audit and system access', TRUE);

INSERT INTO permissions(permission_id, permission_code, description) VALUES
(1, 'ticket.create', 'Create a maintenance ticket'),
(2, 'ticket.read.own', 'Read own maintenance tickets'),
(3, 'ticket.read.all', 'Read all apartment maintenance tickets'),
(4, 'ticket.cancel.own', 'Cancel an eligible own ticket'),
(5, 'ticket.reopen.own', 'Reopen an eligible own ticket'),
(6, 'ticket.review.ai', 'Review AI prediction and risk output'),
(7, 'ticket.override.ai', 'Correct AI output with a reason'),
(8, 'ticket.assign', 'Assign a technician'),
(9, 'ticket.reassign', 'Reassign a technician'),
(10, 'ticket.duplicate.review', 'Review duplicate ticket matches'),
(11, 'ticket.status.update.assigned', 'Update status for assigned jobs'),
(12, 'ticket.note.add.assigned', 'Add repair and progress notes'),
(13, 'ticket.complete.assigned', 'Complete an assigned job'),
(14, 'ticket.attachment.upload', 'Upload authorised ticket evidence'),
(15, 'reports.view', 'View operational reports'),
(16, 'reports.export', 'Export authorised report data'),
(17, 'technician.manage.operational', 'Manage technician availability and workload'),
(18, 'user.manage', 'Create and manage user accounts'),
(19, 'role.manage', 'View and manage role access'),
(20, 'permission.manage', 'Manage role permission mappings'),
(21, 'location.manage', 'Manage buildings, floors, units and areas'),
(22, 'category.manage', 'Manage issue categories'),
(23, 'skill.manage', 'Manage technician skills'),
(24, 'safety_rule.manage', 'Manage safety rules'),
(25, 'system.settings.update', 'Update system configuration settings'),
(26, 'backup.manage', 'Create and review system data exports'),
(27, 'audit.view', 'View audit records'),
(28, 'model.manage', 'View AI model version information'),
(29, 'notification.manage', 'Manage notification configuration'),
(30, 'registration.review', 'Review resident registration requests');

INSERT INTO role_permissions(role_id, permission_id)
SELECT 1, permission_id FROM permissions WHERE permission_code IN (
    'ticket.create','ticket.read.own','ticket.cancel.own','ticket.reopen.own','ticket.attachment.upload'
);
INSERT INTO role_permissions(role_id, permission_id)
SELECT 2, permission_id FROM permissions WHERE permission_code IN (
    'ticket.read.all','ticket.review.ai','ticket.override.ai','ticket.assign','ticket.reassign',
    'ticket.duplicate.review','reports.view','reports.export','technician.manage.operational',
    'notification.manage','registration.review'
);
INSERT INTO role_permissions(role_id, permission_id)
SELECT 3, permission_id FROM permissions WHERE permission_code IN (
    'ticket.status.update.assigned','ticket.note.add.assigned','ticket.complete.assigned','ticket.attachment.upload'
);
INSERT INTO role_permissions(role_id, permission_id)
SELECT 4, permission_id FROM permissions WHERE permission_code IN (
    'user.manage','role.manage','permission.manage','location.manage','category.manage','skill.manage',
    'safety_rule.manage','system.settings.update','backup.manage','audit.view','model.manage',
    'notification.manage','registration.review'
);

INSERT INTO skills(skill_id, skill_name, description, active) VALUES
(1, 'Electrician', 'Electrical faults, wiring, sockets and power issues', TRUE),
(2, 'Plumber', 'Water supply, leaks, pipes and drainage support', TRUE),
(3, 'Lift Technician', 'Lift and elevator maintenance', TRUE),
(4, 'AC Technician', 'Air conditioning and ventilation maintenance', TRUE),
(5, 'Cleaner', 'Cleaning and common area maintenance', TRUE),
(6, 'Pest Controller', 'Pest control and related treatment', TRUE),
(7, 'Carpenter', 'Doors, windows, fittings and carpentry work', TRUE),
(8, 'General Maintenance', 'General building maintenance and miscellaneous work', TRUE),
(9, 'Fire and Safety Technician', 'Fire safety systems, smoke and emergency safety incidents', TRUE),
(10, 'Gas Technician', 'Gas supply, gas smell and gas appliance safety issues', TRUE),
(11, 'Building Technician', 'Structural cracks, ceilings, walls, roofs and building fabric', TRUE),
(12, 'Security Technician', 'Access control, gates, security doors and locks', TRUE);

INSERT INTO issue_categories(category_id, category_code, name, default_skill_id, default_priority, severity_weight, description, active) VALUES
(1, 'ELEC', 'Electrical', 1, 'High', 20, 'Electrical faults and power issues', TRUE),
(2, 'PLUMB', 'Plumbing', 2, 'Medium', 12, 'Water supply, leaks and plumbing issues', TRUE),
(3, 'LIFT', 'Lift', 3, 'High', 22, 'Lift and elevator faults', TRUE),
(4, 'AC', 'Air Conditioning', 4, 'Medium', 8, 'Air conditioning and ventilation faults', TRUE),
(5, 'DRAIN', 'Drainage', 2, 'High', 15, 'Drainage, flooding and sewage problems', TRUE),
(6, 'CLEAN', 'Cleaning', 5, 'Low', 4, 'Cleaning and hygiene issues', TRUE),
(7, 'PEST', 'Pest Control', 6, 'Low', 7, 'Pest and insect control issues', TRUE),
(8, 'CARP', 'Carpentry', 7, 'Low', 5, 'Doors, windows and carpentry work', TRUE),
(9, 'OTHER', 'Other', 8, 'Medium', 5, 'Other general building maintenance issues', TRUE),
(10, 'FIRE', 'Fire and Safety', 9, 'Emergency', 30, 'Fire, smoke, alarm and immediate safety incidents', TRUE),
(11, 'GAS', 'Gas', 10, 'Emergency', 30, 'Gas smell, leakage and gas safety issues', TRUE),
(12, 'STRUCT', 'Structural', 11, 'High', 25, 'Walls, ceilings, roofs, cracks and structural damage', TRUE),
(13, 'SEC', 'Security and Access', 12, 'High', 18, 'Security doors, access control, gates and locks', TRUE);

INSERT INTO category_skill_mappings(category_id, skill_id, required_level, match_weight, is_primary, active) VALUES
(1, 1, 'Advanced', 100, TRUE, TRUE),
(2, 2, 'Intermediate', 100, TRUE, TRUE),
(3, 3, 'Advanced', 100, TRUE, TRUE),
(4, 4, 'Intermediate', 100, TRUE, TRUE),
(5, 2, 'Intermediate', 95, TRUE, TRUE),
(6, 5, 'Basic', 100, TRUE, TRUE),
(7, 6, 'Intermediate', 100, TRUE, TRUE),
(8, 7, 'Intermediate', 100, TRUE, TRUE),
(9, 8, 'Intermediate', 100, TRUE, TRUE),
(10, 9, 'Advanced', 100, TRUE, TRUE),
(10, 1, 'Advanced', 70, FALSE, TRUE),
(11, 10, 'Advanced', 100, TRUE, TRUE),
(12, 11, 'Advanced', 100, TRUE, TRUE),
(13, 12, 'Intermediate', 100, TRUE, TRUE),
(13, 7, 'Intermediate', 60, FALSE, TRUE);

INSERT INTO ticket_status_transitions(from_status, to_status, requires_note, description) VALUES
('Submitted','Analysing',FALSE,'AI analysis begins'),
('Submitted','Cancelled',TRUE,'Resident or admin cancels an invalid ticket'),
('Analysing','Awaiting Review',FALSE,'Normal workflow or manual review required'),
('Analysing','Auto Assigned',FALSE,'Emergency workflow selected a technician'),
('Analysing','Urgent Unassigned',TRUE,'Critical ticket has no suitable technician'),
('Analysing','Cancelled',TRUE,'Ticket cannot continue'),
('Awaiting Review','Assigned',FALSE,'Admin assigns a technician'),
('Awaiting Review','Auto Assigned',FALSE,'Emergency assignment is completed'),
('Awaiting Review','Urgent Unassigned',TRUE,'Urgent case has no available technician'),
('Awaiting Review','Cancelled',TRUE,'Admin cancels the ticket'),
('Urgent Unassigned','Assigned',FALSE,'Admin finds a technician'),
('Urgent Unassigned','Auto Assigned',FALSE,'Technician becomes available and system auto assigns'),
('Urgent Unassigned','Cancelled',TRUE,'Urgent ticket is cancelled with a reason'),
('Auto Assigned','Accepted',FALSE,'Technician accepts emergency assignment'),
('Auto Assigned','Assigned',TRUE,'Admin overrides or reassigns automatic assignment'),
('Auto Assigned','Urgent Unassigned',TRUE,'Automatic technician cannot accept and no replacement exists'),
('Auto Assigned','Cancelled',TRUE,'Emergency ticket cancelled with reason'),
('Assigned','Accepted',FALSE,'Technician accepts assignment'),
('Assigned','Awaiting Review',TRUE,'Technician declines and ticket returns to admin review'),
('Assigned','Cancelled',TRUE,'Assigned ticket cancelled'),
('Accepted','In Progress',FALSE,'Technician starts work'),
('Accepted','On Hold',TRUE,'Accepted job placed on hold'),
('Accepted','Cancelled',TRUE,'Accepted job cancelled'),
('In Progress','On Hold',TRUE,'Waiting for parts or access'),
('In Progress','Resolved',TRUE,'Repair work completed'),
('On Hold','In Progress',FALSE,'Work resumes'),
('On Hold','Resolved',TRUE,'Held work completed'),
('On Hold','Cancelled',TRUE,'Held job cancelled'),
('Resolved','Closed',FALSE,'Resident or admin confirms resolution'),
('Resolved','Reopened',TRUE,'Issue remains unresolved'),
('Closed','Reopened',TRUE,'Issue reoccurs'),
('Reopened','Analysing',FALSE,'Ticket re-enters AI analysis'),
('Reopened','Awaiting Review',FALSE,'Ticket returns to admin review'),
('Reopened','Assigned',FALSE,'Admin assigns a technician after reopening'),
('Reopened','Auto Assigned',FALSE,'Reopened emergency ticket is auto assigned');

INSERT INTO system_settings(setting_id, setting_key, setting_value, value_type, setting_group, description) VALUES
(1, 'apartment_name', 'HelaFixIt Apartment Complex', 'String', 'General', 'Display name of the managed apartment complex'),
(2, 'emergency_risk_threshold', '86', 'Integer', 'Risk', 'Risk score at or above this value is Critical'),
(3, 'high_risk_threshold', '61', 'Integer', 'Risk', 'Risk score at or above this value is High'),
(4, 'medium_risk_threshold', '31', 'Integer', 'Risk', 'Risk score at or above this value is Medium'),
(5, 'duplicate_similarity_threshold', '0.72', 'Decimal', 'AI', 'Cosine similarity threshold for duplicate candidates'),
(6, 'low_confidence_threshold', '0.65', 'Decimal', 'AI', 'Prediction confidence below this value requires admin review'),
(7, 'auto_emergency_assignment', 'true', 'Boolean', 'Assignment', 'Enable automatic assignment for Emergency or Critical tickets'),
(8, 'email_alerts', 'false', 'Boolean', 'Notifications', 'Enable email adapter when configured'),
(9, 'sms_alerts', 'false', 'Boolean', 'Notifications', 'Enable SMS adapter when configured'),
(10, 'browser_alerts', 'true', 'Boolean', 'Notifications', 'Enable browser notifications when configured'),
(11, 'allow_registration', 'true', 'Boolean', 'Authentication', 'Allow residents to submit registration requests'),
(12, 'maintenance_mode', 'false', 'Boolean', 'General', 'Restrict normal access during maintenance'),
(13, 'max_upload_mb', '5', 'Integer', 'Files', 'Maximum uploaded evidence file size'),
(14, 'allowed_upload_types', '["image/jpeg","image/png","image/webp"]', 'JSON', 'Files', 'Allowed image MIME types'),
(15, 'registration_requires_approval', 'true', 'Boolean', 'Authentication', 'Resident registration must be approved by an apartment or system administrator'),
(16, 'active_rule_version', '2.0.0', 'String', 'AI', 'Current safety and risk rule version'),
(17, 'data_retention_days', '365', 'Integer', 'Privacy', 'Operational data retention setting');

INSERT INTO system_settings(setting_key,setting_value,value_type,setting_group,description) VALUES
('system_name','HelaFixIt AI','String','General','Name shown for the maintenance system'),
('allowed_image_types','jpg,jpeg,png,webp','String','Files','File extensions accepted by the maintenance upload interface'),
('default_language','English','String','General','Default interface and resident language selection'),
('technician_default_max_jobs','4','Integer','Assignment','Default maximum active jobs when a technician account is created'),
('notification_retention_days','90','Integer','Notifications','Recommended number of days to retain routine notification records')
ON DUPLICATE KEY UPDATE description=VALUES(description);

INSERT INTO notification_templates(template_code, event_type, channel, subject_template, message_template, active) VALUES
('ticket_created', 'Ticket Created', 'In App', NULL, 'Your maintenance ticket {{ticket_number}} was created.', TRUE),
('ticket_assigned', 'Ticket Assignment', 'In App', NULL, 'Ticket {{ticket_number}} was assigned to {{technician_name}}.', TRUE),
('emergency_assignment', 'Emergency Assignment', 'In App', NULL, 'Emergency ticket {{ticket_number}} requires immediate attention.', TRUE),
('status_changed', 'Status Changed', 'In App', NULL, 'Ticket {{ticket_number}} status changed to {{status}}.', TRUE),
('ticket_completed', 'Ticket Completed', 'In App', NULL, 'Ticket {{ticket_number}} was marked resolved.', TRUE),
('duplicate_found', 'Duplicate Detected', 'In App', NULL, 'A possible duplicate was found for {{ticket_number}}.', TRUE),
('registration_pending', 'Registration Pending', 'In App', NULL, 'A resident registration request is waiting for review.', TRUE);


-- ============================================================================
-- 07_seed_locations_users_and_indexes.sql
-- ============================================================================
-- HelaFixIt AI final application seed data
-- Used during a new database creation after 06_seed_reference_data.sql.
-- Adds complete floors, maintenance areas, prepared Sri Lankan users, technician profiles, skills,
-- resident profiles, registration approval records, notification preferences, and reporting indexes.

-- HelaFixIt AI
-- Complete floor and maintenance area reference data
-- XAMPP / MariaDB compatible
-- Adds the complete floor and maintenance-area reference data for a new database.

USE helafixit_ai;

SET @TOP_RESIDENTIAL_FLOOR = 15;

-- ---------------------------------------------------------------------------
-- 1. Standard floor structure
-- Ground Floor and Floors 1 to 15 are added to every active building.
-- Standard floor records are created and normalised to Active.
-- ---------------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS tmp_floor_template;
CREATE TEMPORARY TABLE tmp_floor_template (
    floor_number SMALLINT PRIMARY KEY,
    floor_name VARCHAR(80) NOT NULL
);

INSERT INTO tmp_floor_template(floor_number, floor_name) VALUES
(0, 'Ground Floor'),
(1, '1st Floor'),
(2, '2nd Floor'),
(3, '3rd Floor'),
(4, '4th Floor'),
(5, '5th Floor'),
(6, '6th Floor'),
(7, '7th Floor'),
(8, '8th Floor'),
(9, '9th Floor'),
(10, '10th Floor'),
(11, '11th Floor'),
(12, '12th Floor'),
(13, '13th Floor'),
(14, '14th Floor'),
(15, '15th Floor');

INSERT INTO floors(building_id, floor_number, name, status)
SELECT b.building_id, ft.floor_number, ft.floor_name, 'Active'
FROM buildings b
CROSS JOIN tmp_floor_template ft
WHERE b.status = 'Active'
  AND NOT EXISTS (
      SELECT 1
      FROM floors f
      WHERE f.building_id = b.building_id
        AND f.floor_number = ft.floor_number
  );

UPDATE floors f
JOIN tmp_floor_template ft ON ft.floor_number = f.floor_number
JOIN buildings b ON b.building_id = f.building_id
SET f.name = ft.floor_name,
    f.status = 'Active'
WHERE b.status = 'Active';

UPDATE buildings
SET declared_floor_count = GREATEST(COALESCE(declared_floor_count, 0), 16)
WHERE status = 'Active';

-- ---------------------------------------------------------------------------
-- 2. Building-wide apartment and shared areas
-- A NULL floor_id means the area is available for every floor in that building.
-- ---------------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS tmp_global_area_template;
CREATE TEMPORARY TABLE tmp_global_area_template (
    area_name VARCHAR(100) PRIMARY KEY,
    area_type ENUM('Private','Common','Service','Outdoor','Other') NOT NULL,
    risk_weight DECIMAL(5,2) NOT NULL
);

INSERT INTO tmp_global_area_template(area_name, area_type, risk_weight) VALUES
('Living Room', 'Private', 2.00),
('Bedroom', 'Private', 2.00),
('Master Bedroom', 'Private', 2.00),
('Bathroom', 'Private', 8.00),
('Kitchen', 'Private', 10.00),
('Balcony', 'Private', 6.00),
('Laundry / Utility Area', 'Private', 8.00),
('Entrance / Main Door', 'Private', 4.00),
('Window Area', 'Private', 4.00),
('Ceiling', 'Private', 7.00),
('Wall', 'Private', 4.00),
('Floor Surface', 'Private', 4.00),
('Internal Electrical Panel', 'Private', 18.00),
('AC Indoor Unit Area', 'Private', 6.00),
('Plumbing Fixture Area', 'Private', 8.00),
('Storeroom', 'Private', 3.00),
('Main Entrance', 'Common', 5.00),
('Reception / Main Lobby', 'Common', 5.00),
('Security Room', 'Service', 8.00),
('Management Office', 'Service', 3.00),
('Mail / Parcel Area', 'Common', 2.00),
('Visitor Waiting Area', 'Common', 2.00),
('Main Electrical Room', 'Service', 28.00),
('Generator Room', 'Service', 28.00),
('Pump Room', 'Service', 20.00),
('Water Tank Area', 'Service', 16.00),
('Fire Control Room', 'Service', 28.00),
('CCTV / Network Room', 'Service', 14.00),
('Lift Machine Room', 'Service', 28.00),
('Garbage Collection Room', 'Service', 16.00),
('Waste Storage Area', 'Service', 16.00),
('Parking Area', 'Common', 10.00),
('Basement Parking Area', 'Common', 12.00),
('Bicycle Parking Area', 'Common', 4.00),
('Garden / Landscape Area', 'Outdoor', 3.00),
('Playground', 'Outdoor', 5.00),
('Swimming Pool Area', 'Outdoor', 16.00),
('Gym / Fitness Area', 'Common', 6.00),
('Community Hall', 'Common', 4.00),
('Rooftop / Roof Area', 'Outdoor', 18.00),
('Roof Drainage Area', 'Outdoor', 20.00),
('AC Outdoor Unit Area', 'Service', 14.00),
('Solar Panel Area', 'Service', 18.00),
('Water Meter Area', 'Service', 10.00),
('Main Drainage Area', 'Service', 20.00),
('Sewer / Manhole Area', 'Service', 28.00),
('Fire Assembly Point', 'Outdoor', 6.00),
('Loading / Service Area', 'Service', 8.00),
('Perimeter / Boundary Area', 'Outdoor', 8.00),
('Main Gate / Vehicle Entrance', 'Common', 10.00),
('Intercom / Access Control Area', 'Service', 10.00);

INSERT INTO areas(building_id, floor_id, name, area_type, risk_weight, status)
SELECT b.building_id, NULL, ga.area_name, ga.area_type, ga.risk_weight, 'Active'
FROM buildings b
CROSS JOIN tmp_global_area_template ga
WHERE b.status = 'Active'
  AND NOT EXISTS (
      SELECT 1
      FROM areas a
      WHERE a.building_id = b.building_id
        AND a.floor_id IS NULL
        AND a.name = ga.area_name
  );

UPDATE areas a
JOIN buildings b ON b.building_id = a.building_id
JOIN tmp_global_area_template ga ON ga.area_name = a.name
SET a.area_type = ga.area_type,
    a.risk_weight = ga.risk_weight,
    a.status = 'Active'
WHERE b.status = 'Active'
  AND a.floor_id IS NULL;

-- ---------------------------------------------------------------------------
-- 3. Floor-specific common and service areas
-- These are created for every active configured floor.
-- ---------------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS tmp_floor_area_template;
CREATE TEMPORARY TABLE tmp_floor_area_template (
    area_name VARCHAR(100) PRIMARY KEY,
    area_type ENUM('Private','Common','Service','Outdoor','Other') NOT NULL,
    risk_weight DECIMAL(5,2) NOT NULL
);

INSERT INTO tmp_floor_area_template(area_name, area_type, risk_weight) VALUES
('Main Corridor', 'Common', 5.00),
('Lift Lobby', 'Common', 14.00),
('Staircase', 'Common', 10.00),
('Fire Exit', 'Common', 20.00),
('Common Washroom', 'Common', 8.00),
('Electrical Riser', 'Service', 24.00),
('Plumbing Riser', 'Service', 16.00),
('Service Duct', 'Service', 16.00),
('Fire Hose / Reel Area', 'Service', 22.00),
('Emergency Lighting Area', 'Service', 16.00);

INSERT INTO areas(building_id, floor_id, name, area_type, risk_weight, status)
SELECT f.building_id, f.floor_id, fa.area_name, fa.area_type, fa.risk_weight, 'Active'
FROM floors f
JOIN buildings b ON b.building_id = f.building_id
CROSS JOIN tmp_floor_area_template fa
WHERE f.status = 'Active'
  AND b.status = 'Active'
  AND NOT EXISTS (
      SELECT 1
      FROM areas a
      WHERE a.building_id = f.building_id
        AND a.floor_id = f.floor_id
        AND a.name = fa.area_name
  );

UPDATE areas a
JOIN floors f ON f.floor_id = a.floor_id
JOIN buildings b ON b.building_id = a.building_id
JOIN tmp_floor_area_template fa ON fa.area_name = a.name
SET a.area_type = fa.area_type,
    a.risk_weight = fa.risk_weight,
    a.status = 'Active'
WHERE f.status = 'Active'
  AND b.status = 'Active';

DROP TEMPORARY TABLE IF EXISTS tmp_floor_template;
DROP TEMPORARY TABLE IF EXISTS tmp_global_area_template;
DROP TEMPORARY TABLE IF EXISTS tmp_floor_area_template;

-- ---------------------------------------------------------------------------
-- 4. Validation summary
-- ---------------------------------------------------------------------------
SELECT
    b.building_id,
    b.block_code,
    b.name AS building_name,
    COUNT(DISTINCT f.floor_id) AS active_floors,
    COUNT(DISTINCT a.area_id) AS active_areas
FROM buildings b
LEFT JOIN floors f
    ON f.building_id = b.building_id
   AND f.status = 'Active'
LEFT JOIN areas a
    ON a.building_id = b.building_id
   AND a.status = 'Active'
WHERE b.status = 'Active'
GROUP BY b.building_id, b.block_code, b.name
ORDER BY b.block_code;

SELECT
    b.block_code,
    f.floor_number,
    f.name AS floor_name,
    COUNT(a.area_id) AS floor_specific_areas
FROM buildings b
JOIN floors f ON f.building_id = b.building_id AND f.status = 'Active'
LEFT JOIN areas a ON a.floor_id = f.floor_id AND a.status = 'Active'
WHERE b.status = 'Active'
GROUP BY b.block_code, f.floor_id, f.floor_number, f.name
ORDER BY b.block_code, f.floor_number;

-- HelaFixIt AI
-- Initial Sri Lankan user accounts for the apartment maintenance system
-- Runs after the complete floor and area seed section.
-- Seeded accounts use a temporary password hash and must change the password after first sign in.
-- Passwords are stored as PBKDF2 SHA-256 hashes and users must change them after first sign in.

USE helafixit_ai;
SET NAMES utf8mb4;
START TRANSACTION;

SET @password_hash = 'REPLACE_WITH_VALID_PBKDF2_HASH_BEFORE_IMPORT';
SET @complex_id = (SELECT complex_id FROM apartment_complexes WHERE status='Active' ORDER BY complex_id LIMIT 1);
SET @building_id = (SELECT building_id FROM buildings WHERE status='Active' ORDER BY building_id LIMIT 1);
SET @first_floor_id = (SELECT floor_id FROM floors WHERE building_id=@building_id AND status='Active' ORDER BY floor_number, floor_id LIMIT 1);
SET @floor_1 = COALESCE((SELECT floor_id FROM floors WHERE building_id=@building_id AND floor_number=1 AND status='Active' LIMIT 1), @first_floor_id);
SET @floor_2 = COALESCE((SELECT floor_id FROM floors WHERE building_id=@building_id AND floor_number=2 AND status='Active' LIMIT 1), @first_floor_id);
SET @floor_3 = COALESCE((SELECT floor_id FROM floors WHERE building_id=@building_id AND floor_number=3 AND status='Active' LIMIT 1), @first_floor_id);
SET @floor_4 = COALESCE((SELECT floor_id FROM floors WHERE building_id=@building_id AND floor_number=4 AND status='Active' LIMIT 1), @first_floor_id);
SET @floor_5 = COALESCE((SELECT floor_id FROM floors WHERE building_id=@building_id AND floor_number=5 AND status='Active' LIMIT 1), @first_floor_id);
SET @floor_6 = COALESCE((SELECT floor_id FROM floors WHERE building_id=@building_id AND floor_number=6 AND status='Active' LIMIT 1), @first_floor_id);
SET @floor_7 = COALESCE((SELECT floor_id FROM floors WHERE building_id=@building_id AND floor_number=7 AND status='Active' LIMIT 1), @first_floor_id);
SET @floor_8 = COALESCE((SELECT floor_id FROM floors WHERE building_id=@building_id AND floor_number=8 AND status='Active' LIMIT 1), @first_floor_id);
SET @floor_9 = COALESCE((SELECT floor_id FROM floors WHERE building_id=@building_id AND floor_number=9 AND status='Active' LIMIT 1), @first_floor_id);
SET @floor_10 = COALESCE((SELECT floor_id FROM floors WHERE building_id=@building_id AND floor_number=10 AND status='Active' LIMIT 1), @first_floor_id);
SET @floor_11 = COALESCE((SELECT floor_id FROM floors WHERE building_id=@building_id AND floor_number=11 AND status='Active' LIMIT 1), @first_floor_id);
SET @floor_12 = COALESCE((SELECT floor_id FROM floors WHERE building_id=@building_id AND floor_number=12 AND status='Active' LIMIT 1), @first_floor_id);

-- Apartment Admin accounts
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Nadeesha Perera','nadeesha.perera@helafixit.lk','+94711234567',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE
FROM roles r WHERE r.role_code='apartment_admin' AND NOT EXISTS (SELECT 1 FROM users WHERE email='nadeesha.perera@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Harini Wijesinghe','harini.wijesinghe@helafixit.lk','+94721234568',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE
FROM roles r WHERE r.role_code='apartment_admin' AND NOT EXISTS (SELECT 1 FROM users WHERE email='harini.wijesinghe@helafixit.lk');

INSERT INTO apartment_admin_profiles(user_id,primary_building_id,job_title,can_review_emergencies,active)
SELECT u.user_id,@building_id,'Apartment Administrator',TRUE,TRUE FROM users u
WHERE u.email='nadeesha.perera@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM apartment_admin_profiles p WHERE p.user_id=u.user_id);
INSERT INTO apartment_admin_profiles(user_id,primary_building_id,job_title,can_review_emergencies,active)
SELECT u.user_id,@building_id,'Apartment Administrator',TRUE,TRUE FROM users u
WHERE u.email='harini.wijesinghe@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM apartment_admin_profiles p WHERE p.user_id=u.user_id);

-- Technician accounts covering the maintenance skills used by the system
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Nuwan Silva','nuwan.silva@helafixit.lk','+94761234569',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='technician' AND NOT EXISTS (SELECT 1 FROM users WHERE email='nuwan.silva@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Chamara Perera','chamara.perera@helafixit.lk','+94771234570',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='technician' AND NOT EXISTS (SELECT 1 FROM users WHERE email='chamara.perera@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Supun Jayasinghe','supun.jayasinghe@helafixit.lk','+94781234571',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='technician' AND NOT EXISTS (SELECT 1 FROM users WHERE email='supun.jayasinghe@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Dinesh Fernando','dinesh.fernando@helafixit.lk','+94741234572',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='technician' AND NOT EXISTS (SELECT 1 FROM users WHERE email='dinesh.fernando@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Isuru Madushan','isuru.madushan@helafixit.lk','+94751234573',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='technician' AND NOT EXISTS (SELECT 1 FROM users WHERE email='isuru.madushan@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Tharindu Kumara','tharindu.kumara@helafixit.lk','+94761234574',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='technician' AND NOT EXISTS (SELECT 1 FROM users WHERE email='tharindu.kumara@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Lahiru Senanayake','lahiru.senanayake@helafixit.lk','+94771234575',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='technician' AND NOT EXISTS (SELECT 1 FROM users WHERE email='lahiru.senanayake@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Ruwan Bandara','ruwan.bandara@helafixit.lk','+94781234576',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='technician' AND NOT EXISTS (SELECT 1 FROM users WHERE email='ruwan.bandara@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Asanka Weerasinghe','asanka.weerasinghe@helafixit.lk','+94741234577',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='technician' AND NOT EXISTS (SELECT 1 FROM users WHERE email='asanka.weerasinghe@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Pradeep Rajapaksha','pradeep.rajapaksha@helafixit.lk','+94751234578',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='technician' AND NOT EXISTS (SELECT 1 FROM users WHERE email='pradeep.rajapaksha@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Mahesh Karunaratne','mahesh.karunaratne@helafixit.lk','+94761234579',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='technician' AND NOT EXISTS (SELECT 1 FROM users WHERE email='mahesh.karunaratne@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Sachith De Silva','sachith.desilva@helafixit.lk','+94771234580',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='technician' AND NOT EXISTS (SELECT 1 FROM users WHERE email='sachith.desilva@helafixit.lk');

-- Technician profile helper inserts
INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,can_work_after_hours,service_area,years_experience,rating,active,last_availability_change_at)
SELECT u.user_id,'HFT-EL-001',@building_id,'Available',0,5,TRUE,TRUE,'Apartment complex',6.0,4.60,TRUE,NOW() FROM users u WHERE u.email='nuwan.silva@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_profiles p WHERE p.user_id=u.user_id);
INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,can_work_after_hours,service_area,years_experience,rating,active,last_availability_change_at)
SELECT u.user_id,'HFT-PL-002',@building_id,'Available',0,5,TRUE,TRUE,'Apartment complex',7.0,4.55,TRUE,NOW() FROM users u WHERE u.email='chamara.perera@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_profiles p WHERE p.user_id=u.user_id);
INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,can_work_after_hours,service_area,years_experience,rating,active,last_availability_change_at)
SELECT u.user_id,'HFT-LF-003',@building_id,'Available',0,4,TRUE,TRUE,'Apartment complex',8.0,4.75,TRUE,NOW() FROM users u WHERE u.email='supun.jayasinghe@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_profiles p WHERE p.user_id=u.user_id);
INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,can_work_after_hours,service_area,years_experience,rating,active,last_availability_change_at)
SELECT u.user_id,'HFT-AC-004',@building_id,'Available',0,5,TRUE,FALSE,'Apartment complex',5.0,4.40,TRUE,NOW() FROM users u WHERE u.email='dinesh.fernando@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_profiles p WHERE p.user_id=u.user_id);
INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,can_work_after_hours,service_area,years_experience,rating,active,last_availability_change_at)
SELECT u.user_id,'HFT-CL-005',@building_id,'Available',0,6,FALSE,FALSE,'Apartment complex',4.0,4.30,TRUE,NOW() FROM users u WHERE u.email='isuru.madushan@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_profiles p WHERE p.user_id=u.user_id);
INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,can_work_after_hours,service_area,years_experience,rating,active,last_availability_change_at)
SELECT u.user_id,'HFT-PC-006',@building_id,'Available',0,5,FALSE,FALSE,'Apartment complex',5.0,4.35,TRUE,NOW() FROM users u WHERE u.email='tharindu.kumara@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_profiles p WHERE p.user_id=u.user_id);
INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,can_work_after_hours,service_area,years_experience,rating,active,last_availability_change_at)
SELECT u.user_id,'HFT-CP-007',@building_id,'Available',0,5,FALSE,FALSE,'Apartment complex',6.0,4.45,TRUE,NOW() FROM users u WHERE u.email='lahiru.senanayake@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_profiles p WHERE p.user_id=u.user_id);
INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,can_work_after_hours,service_area,years_experience,rating,active,last_availability_change_at)
SELECT u.user_id,'HFT-GM-008',@building_id,'Available',0,6,TRUE,TRUE,'Apartment complex',9.0,4.65,TRUE,NOW() FROM users u WHERE u.email='ruwan.bandara@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_profiles p WHERE p.user_id=u.user_id);
INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,can_work_after_hours,service_area,years_experience,rating,active,last_availability_change_at)
SELECT u.user_id,'HFT-FS-009',@building_id,'Available',0,4,TRUE,TRUE,'Apartment complex',8.0,4.80,TRUE,NOW() FROM users u WHERE u.email='asanka.weerasinghe@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_profiles p WHERE p.user_id=u.user_id);
INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,can_work_after_hours,service_area,years_experience,rating,active,last_availability_change_at)
SELECT u.user_id,'HFT-GS-010',@building_id,'Available',0,4,TRUE,TRUE,'Apartment complex',7.0,4.70,TRUE,NOW() FROM users u WHERE u.email='pradeep.rajapaksha@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_profiles p WHERE p.user_id=u.user_id);
INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,can_work_after_hours,service_area,years_experience,rating,active,last_availability_change_at)
SELECT u.user_id,'HFT-BD-011',@building_id,'Available',0,5,TRUE,TRUE,'Apartment complex',10.0,4.70,TRUE,NOW() FROM users u WHERE u.email='mahesh.karunaratne@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_profiles p WHERE p.user_id=u.user_id);
INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,can_work_after_hours,service_area,years_experience,rating,active,last_availability_change_at)
SELECT u.user_id,'HFT-SC-012',@building_id,'Available',0,5,TRUE,TRUE,'Apartment complex',6.0,4.50,TRUE,NOW() FROM users u WHERE u.email='sachith.desilva@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_profiles p WHERE p.user_id=u.user_id);

-- Primary technician skills
INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,experience_years,is_primary)
SELECT t.technician_id,s.skill_id,'Advanced',TRUE,6.0,TRUE FROM technician_profiles t JOIN users u ON u.user_id=t.user_id JOIN skills s ON s.skill_name='Electrician' WHERE u.email='nuwan.silva@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_skills x WHERE x.technician_id=t.technician_id AND x.skill_id=s.skill_id);
INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,experience_years,is_primary)
SELECT t.technician_id,s.skill_id,'Advanced',TRUE,7.0,TRUE FROM technician_profiles t JOIN users u ON u.user_id=t.user_id JOIN skills s ON s.skill_name='Plumber' WHERE u.email='chamara.perera@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_skills x WHERE x.technician_id=t.technician_id AND x.skill_id=s.skill_id);
INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,experience_years,is_primary)
SELECT t.technician_id,s.skill_id,'Expert',TRUE,8.0,TRUE FROM technician_profiles t JOIN users u ON u.user_id=t.user_id JOIN skills s ON s.skill_name='Lift Technician' WHERE u.email='supun.jayasinghe@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_skills x WHERE x.technician_id=t.technician_id AND x.skill_id=s.skill_id);
INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,experience_years,is_primary)
SELECT t.technician_id,s.skill_id,'Advanced',TRUE,5.0,TRUE FROM technician_profiles t JOIN users u ON u.user_id=t.user_id JOIN skills s ON s.skill_name='AC Technician' WHERE u.email='dinesh.fernando@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_skills x WHERE x.technician_id=t.technician_id AND x.skill_id=s.skill_id);
INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,experience_years,is_primary)
SELECT t.technician_id,s.skill_id,'Advanced',TRUE,4.0,TRUE FROM technician_profiles t JOIN users u ON u.user_id=t.user_id JOIN skills s ON s.skill_name='Cleaner' WHERE u.email='isuru.madushan@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_skills x WHERE x.technician_id=t.technician_id AND x.skill_id=s.skill_id);
INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,experience_years,is_primary)
SELECT t.technician_id,s.skill_id,'Advanced',TRUE,5.0,TRUE FROM technician_profiles t JOIN users u ON u.user_id=t.user_id JOIN skills s ON s.skill_name='Pest Controller' WHERE u.email='tharindu.kumara@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_skills x WHERE x.technician_id=t.technician_id AND x.skill_id=s.skill_id);
INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,experience_years,is_primary)
SELECT t.technician_id,s.skill_id,'Advanced',TRUE,6.0,TRUE FROM technician_profiles t JOIN users u ON u.user_id=t.user_id JOIN skills s ON s.skill_name='Carpenter' WHERE u.email='lahiru.senanayake@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_skills x WHERE x.technician_id=t.technician_id AND x.skill_id=s.skill_id);
INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,experience_years,is_primary)
SELECT t.technician_id,s.skill_id,'Expert',TRUE,9.0,TRUE FROM technician_profiles t JOIN users u ON u.user_id=t.user_id JOIN skills s ON s.skill_name='General Maintenance' WHERE u.email='ruwan.bandara@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_skills x WHERE x.technician_id=t.technician_id AND x.skill_id=s.skill_id);
INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,experience_years,is_primary)
SELECT t.technician_id,s.skill_id,'Expert',TRUE,8.0,TRUE FROM technician_profiles t JOIN users u ON u.user_id=t.user_id JOIN skills s ON s.skill_name='Fire and Safety Technician' WHERE u.email='asanka.weerasinghe@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_skills x WHERE x.technician_id=t.technician_id AND x.skill_id=s.skill_id);
INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,experience_years,is_primary)
SELECT t.technician_id,s.skill_id,'Expert',TRUE,7.0,TRUE FROM technician_profiles t JOIN users u ON u.user_id=t.user_id JOIN skills s ON s.skill_name='Gas Technician' WHERE u.email='pradeep.rajapaksha@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_skills x WHERE x.technician_id=t.technician_id AND x.skill_id=s.skill_id);
INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,experience_years,is_primary)
SELECT t.technician_id,s.skill_id,'Expert',TRUE,10.0,TRUE FROM technician_profiles t JOIN users u ON u.user_id=t.user_id JOIN skills s ON s.skill_name='Building Technician' WHERE u.email='mahesh.karunaratne@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_skills x WHERE x.technician_id=t.technician_id AND x.skill_id=s.skill_id);
INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,experience_years,is_primary)
SELECT t.technician_id,s.skill_id,'Advanced',TRUE,6.0,TRUE FROM technician_profiles t JOIN users u ON u.user_id=t.user_id JOIN skills s ON s.skill_name='Security Technician' WHERE u.email='sachith.desilva@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM technician_skills x WHERE x.technician_id=t.technician_id AND x.skill_id=s.skill_id);

-- Approved Resident accounts
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Hasini Perera','hasini.perera@helafixit.lk','+94711234581',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='resident' AND NOT EXISTS (SELECT 1 FROM users WHERE email='hasini.perera@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Kavindu Silva','kavindu.silva@helafixit.lk','+94721234582',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='resident' AND NOT EXISTS (SELECT 1 FROM users WHERE email='kavindu.silva@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Dinithi Jayawardena','dinithi.jayawardena@helafixit.lk','+94761234583',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='resident' AND NOT EXISTS (SELECT 1 FROM users WHERE email='dinithi.jayawardena@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Sachini Fernando','sachini.fernando@helafixit.lk','+94771234584',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='resident' AND NOT EXISTS (SELECT 1 FROM users WHERE email='sachini.fernando@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Nimesh Wijesinghe','nimesh.wijesinghe@helafixit.lk','+94781234585',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='resident' AND NOT EXISTS (SELECT 1 FROM users WHERE email='nimesh.wijesinghe@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Oshadi Gunasekara','oshadi.gunasekara@helafixit.lk','+94741234586',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='resident' AND NOT EXISTS (SELECT 1 FROM users WHERE email='oshadi.gunasekara@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Malith Senanayake','malith.senanayake@helafixit.lk','+94751234587',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='resident' AND NOT EXISTS (SELECT 1 FROM users WHERE email='malith.senanayake@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Ishara Bandara','ishara.bandara@helafixit.lk','+94761234588',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='resident' AND NOT EXISTS (SELECT 1 FROM users WHERE email='ishara.bandara@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Piumi Rathnayake','piumi.rathnayake@helafixit.lk','+94771234589',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='resident' AND NOT EXISTS (SELECT 1 FROM users WHERE email='piumi.rathnayake@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Shehan Peiris','shehan.peiris@helafixit.lk','+94781234590',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='resident' AND NOT EXISTS (SELECT 1 FROM users WHERE email='shehan.peiris@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Thilini Abeysekara','thilini.abeysekara@helafixit.lk','+94741234591',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='resident' AND NOT EXISTS (SELECT 1 FROM users WHERE email='thilini.abeysekara@helafixit.lk');
INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
SELECT r.role_id,@complex_id,'Akila Dissanayake','akila.dissanayake@helafixit.lk','+94751234592',@password_hash,'Active',TRUE,TRUE,NOW(),FALSE FROM roles r WHERE r.role_code='resident' AND NOT EXISTS (SELECT 1 FROM users WHERE email='akila.dissanayake@helafixit.lk');

-- Resident profiles
INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
SELECT u.user_id,@building_id,@floor_1,'A-101','Owner','English','In App','Active' FROM users u WHERE u.email='hasini.perera@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM resident_profiles p WHERE p.user_id=u.user_id);
INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
SELECT u.user_id,@building_id,@floor_2,'A-204','Tenant','Sinhala','In App','Active' FROM users u WHERE u.email='kavindu.silva@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM resident_profiles p WHERE p.user_id=u.user_id);
INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
SELECT u.user_id,@building_id,@floor_3,'A-306','Family','Singlish','In App','Active' FROM users u WHERE u.email='dinithi.jayawardena@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM resident_profiles p WHERE p.user_id=u.user_id);
INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
SELECT u.user_id,@building_id,@floor_4,'A-408','Owner','Mixed','Email','Active' FROM users u WHERE u.email='sachini.fernando@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM resident_profiles p WHERE p.user_id=u.user_id);
INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
SELECT u.user_id,@building_id,@floor_5,'A-503','Tenant','English','In App','Active' FROM users u WHERE u.email='nimesh.wijesinghe@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM resident_profiles p WHERE p.user_id=u.user_id);
INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
SELECT u.user_id,@building_id,@floor_6,'A-605','Family','Sinhala','In App','Active' FROM users u WHERE u.email='oshadi.gunasekara@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM resident_profiles p WHERE p.user_id=u.user_id);
INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
SELECT u.user_id,@building_id,@floor_7,'A-707','Owner','Singlish','Email','Active' FROM users u WHERE u.email='malith.senanayake@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM resident_profiles p WHERE p.user_id=u.user_id);
INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
SELECT u.user_id,@building_id,@floor_8,'A-802','Tenant','Mixed','In App','Active' FROM users u WHERE u.email='ishara.bandara@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM resident_profiles p WHERE p.user_id=u.user_id);
INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
SELECT u.user_id,@building_id,@floor_9,'A-904','Family','English','In App','Active' FROM users u WHERE u.email='piumi.rathnayake@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM resident_profiles p WHERE p.user_id=u.user_id);
INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
SELECT u.user_id,@building_id,@floor_10,'A-1006','Owner','Sinhala','Email','Active' FROM users u WHERE u.email='shehan.peiris@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM resident_profiles p WHERE p.user_id=u.user_id);
INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
SELECT u.user_id,@building_id,@floor_11,'A-1108','Tenant','Singlish','In App','Active' FROM users u WHERE u.email='thilini.abeysekara@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM resident_profiles p WHERE p.user_id=u.user_id);
INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
SELECT u.user_id,@building_id,@floor_12,'A-1203','Family','Mixed','In App','Active' FROM users u WHERE u.email='akila.dissanayake@helafixit.lk' AND NOT EXISTS (SELECT 1 FROM resident_profiles p WHERE p.user_id=u.user_id);

-- Keep an approval record for the preloaded Resident accounts so the normal registration rule remains traceable.
INSERT INTO resident_registration_requests(full_name,email,phone,complex_id,building_id,floor_id,unit_number,resident_type,preferred_language,contact_preference,password_hash,request_status,requested_at,reviewed_at,review_note,created_user_id)
SELECT u.full_name,u.email,u.phone,u.complex_id,p.building_id,p.floor_id,p.unit_number,p.resident_type,p.preferred_language,p.contact_preference,u.password_hash,'Approved',u.created_at,u.created_at,'Approved initial resident account',u.user_id
FROM users u JOIN roles r ON r.role_id=u.role_id JOIN resident_profiles p ON p.user_id=u.user_id
WHERE r.role_code='resident' AND u.email LIKE '%@helafixit.lk' AND u.email IN (
'hasini.perera@helafixit.lk','kavindu.silva@helafixit.lk','dinithi.jayawardena@helafixit.lk','sachini.fernando@helafixit.lk',
'nimesh.wijesinghe@helafixit.lk','oshadi.gunasekara@helafixit.lk','malith.senanayake@helafixit.lk','ishara.bandara@helafixit.lk',
'piumi.rathnayake@helafixit.lk','shehan.peiris@helafixit.lk','thilini.abeysekara@helafixit.lk','akila.dissanayake@helafixit.lk')
AND NOT EXISTS (SELECT 1 FROM resident_registration_requests rr WHERE rr.email=u.email AND rr.request_status='Approved');

-- Notification preferences for every inserted account
INSERT INTO notification_preferences(user_id)
SELECT u.user_id FROM users u
WHERE u.email IN (
'nadeesha.perera@helafixit.lk','harini.wijesinghe@helafixit.lk','nuwan.silva@helafixit.lk','chamara.perera@helafixit.lk',
'supun.jayasinghe@helafixit.lk','dinesh.fernando@helafixit.lk','isuru.madushan@helafixit.lk','tharindu.kumara@helafixit.lk',
'lahiru.senanayake@helafixit.lk','ruwan.bandara@helafixit.lk','asanka.weerasinghe@helafixit.lk','pradeep.rajapaksha@helafixit.lk',
'mahesh.karunaratne@helafixit.lk','sachith.desilva@helafixit.lk','hasini.perera@helafixit.lk','kavindu.silva@helafixit.lk',
'dinithi.jayawardena@helafixit.lk','sachini.fernando@helafixit.lk','nimesh.wijesinghe@helafixit.lk','oshadi.gunasekara@helafixit.lk',
'malith.senanayake@helafixit.lk','ishara.bandara@helafixit.lk','piumi.rathnayake@helafixit.lk','shehan.peiris@helafixit.lk',
'thilini.abeysekara@helafixit.lk','akila.dissanayake@helafixit.lk')
AND NOT EXISTS (SELECT 1 FROM notification_preferences n WHERE n.user_id=u.user_id);

COMMIT;

-- Verification summary
SELECT r.role_name, COUNT(*) AS added_user_count
FROM users u JOIN roles r ON r.role_id=u.role_id
WHERE u.email LIKE '%@helafixit.lk'
GROUP BY r.role_name
ORDER BY r.role_name;

-- Reporting and administration indexes
-- Helpful indexes for reporting and administration. Duplicate index names are avoided through information_schema checks.
SET @sql = IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='helafixit_ai' AND table_name='maintenance_tickets' AND index_name='idx_stage5_ticket_reporting')=0,
'CREATE INDEX idx_stage5_ticket_reporting ON maintenance_tickets(building_id,current_status,current_priority,submitted_at)','SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @sql = IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='helafixit_ai' AND table_name='ticket_assignments' AND index_name='idx_stage5_assignment_reporting')=0,
'CREATE INDEX idx_stage5_assignment_reporting ON ticket_assignments(technician_id,assignment_method,assignment_status,assigned_at)','SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @sql = IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='helafixit_ai' AND table_name='audit_logs' AND index_name='idx_stage5_audit_filter')=0,
'CREATE INDEX idx_stage5_audit_filter ON audit_logs(action_type,entity_type,created_at)','SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
