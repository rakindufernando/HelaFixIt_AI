# HelaFixIt AI Database

This folder contains the final database creation source and supporting database documentation for the HelaFixIt AI system.

## Recommended database creation

For a clean XAMPP / MariaDB installation, import:

`helafixit_ai_complete_setup.sql`

This single script creates the current database schema, triggers, views, stored procedures, reference data, complete floors and maintenance areas, and prepared application users.

After creation, run `08_validation_queries_XAMPP.sql` to verify the installed database.

## Modular SQL source

The same database source is also separated into:

1. `01_create_database.sql`
2. `02_schema.sql`
3. `03_triggers.sql`
4. `04_views.sql`
5. `05_stored_procedures.sql`
6. `06_seed_reference_data.sql`
7. `07_seed_locations_users_and_indexes.sql`

These files are kept to make the database design and implementation easier to review.

## Supporting assessment files

- `database_dictionary.csv` documents the main database fields and tables.
- `ERD.mmd` contains the editable ER diagram source.
- `08_validation_queries_XAMPP.sql` checks the installed database structure and important data.
- `XAMPP_DATABASE_SETUP.txt` contains the local database setup sequence.
- `BACKUP_RESTORE_GUIDE.md` documents the project backup and restore approach.

The database uses `utf8mb4` so English, Sinhala, Singlish and mixed-language maintenance text can be stored correctly.
