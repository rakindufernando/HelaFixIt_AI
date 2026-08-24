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
-- All accounts below use the initial password helafixit@321
-- Passwords are stored as PBKDF2 SHA-256 hashes and users must change them after first sign in.

USE helafixit_ai;
SET NAMES utf8mb4;
START TRANSACTION;

SET @password_hash = 'pbkdf2:sha256:600000$evdPNGIS9zrCwufy$2a2a87ab0f630b87273c6ed79ad122d06d75743c3d418e8bea02b60b794a798d';
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
