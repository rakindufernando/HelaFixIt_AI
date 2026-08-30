-- HelaFixIt AI existing-database upgrade
-- Adds the separate temporary-password store used by System Admin password recovery.
-- Safe to run more than once in phpMyAdmin.

USE `helafixit_ai`;

CREATE TABLE IF NOT EXISTS temporary_passwords (
    temporary_password_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    expires_at DATETIME NOT NULL,
    created_by BIGINT UNSIGNED NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    used_at DATETIME NULL,
    CONSTRAINT fk_temp_password_user
        FOREIGN KEY (user_id) REFERENCES users(user_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_temp_password_created_by
        FOREIGN KEY (created_by) REFERENCES users(user_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    UNIQUE KEY uq_temp_password_user (user_id),
    KEY idx_temp_password_active (user_id, used_at, expires_at)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci;

-- Direct-table verification that does not require information_schema access.
SELECT COUNT(*) AS temporary_password_records FROM temporary_passwords;
