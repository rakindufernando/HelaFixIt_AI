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

CREATE TABLE temporary_passwords (
    temporary_password_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    expires_at DATETIME NOT NULL,
    created_by BIGINT UNSIGNED NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    used_at DATETIME NULL,
    CONSTRAINT fk_temp_password_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_temp_password_created_by FOREIGN KEY (created_by) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL,
    UNIQUE KEY uq_temp_password_user (user_id),
    KEY idx_temp_password_active (user_id, used_at, expires_at)
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
    KEY idx_stage5_ticket_reporting (building_id, current_status, current_priority, submitted_at),
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
    KEY idx_assignment_method (assignment_method, assigned_at),
    KEY idx_stage5_assignment_reporting (technician_id, assignment_method, assignment_status, assigned_at)
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
    KEY idx_audit_created (created_at),
    KEY idx_stage5_audit_filter (action_type, entity_type, created_at)
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
