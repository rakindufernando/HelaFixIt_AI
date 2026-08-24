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
