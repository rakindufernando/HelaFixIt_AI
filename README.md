# HelaFixIt AI

HelaFixIt AI is a Flask and MariaDB apartment maintenance management system with four roles
Resident, Apartment Admin, Technician and System Admin.

The application includes resident registration approval, role based authentication, maintenance ticket workflows, multilingual AI assisted category and priority prediction, risk scoring, safety rules, duplicate checking, technician recommendation, emergency assignment, notifications, reporting, user management, settings, audit logs and local data export.

## Main folders

- `Frontend` contains HTML, CSS and JavaScript pages.
- `Backend` contains the Flask application, routes, services and validation logic.
- `Database` contains the MariaDB schema, upgrade scripts, reference data and setup files.
- `AI-model` contains the complete dataset, training scripts, saved models, rule files and evaluation outputs.
- `Documentation` contains system verification and AI file information.

## Local database

For a new local database, import `Database/helafixit_ai_complete_setup.sql` using phpMyAdmin.
For an existing database, keep the current records and apply only the numbered upgrade scripts that have not already been applied.

## Backend

Create a Python virtual environment locally and install the packages listed in `Backend/requirements.txt`.
Copy `Backend/.env.example` to `Backend/.env` and set the local database connection if the XAMPP MariaDB configuration is different from the defaults.
Run the application from the `Backend` folder using `py app.py`.

The virtual environment and local `.env` file are intentionally excluded from the project package.
