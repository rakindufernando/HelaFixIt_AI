# HelaFixIt AI

## AI-Based Multilingual Apartment Maintenance Ticket Prioritization, Risk Scoring, and Technician Recommendation System

HelaFixIt AI is a web-based apartment maintenance management system developed to improve how apartment maintenance requests are reported, analysed, prioritised, assigned and completed.

The system combines a normal maintenance ticket management workflow with a locally trained machine learning component. Maintenance requests can be submitted in English, Sinhala, Singlish and mixed-language text. The system analyses each request and provides decision-support information such as issue category, priority, risk level, safety information and technician recommendations.

The application contains four main user roles

- Resident
- Apartment Administrator
- Technician
- System Administrator

The core AI functionality is executed locally using Python and scikit-learn models. An external AI prediction API is not required for the main maintenance ticket analysis.

---

## Project Background

Apartment maintenance requests can include problems such as electrical faults, plumbing leaks, lift failures, water supply issues, fire and safety risks, appliance faults and other building-related issues.

When maintenance requests are processed manually, several problems can occur

- urgent requests may not be identified quickly
- tickets can be assigned to the wrong maintenance category
- safety-related issues may not receive sufficient attention
- duplicate maintenance requests can increase workload
- selecting a suitable technician can take additional time
- maintenance staff may have difficulty managing large numbers of tickets
- residents may have limited visibility of maintenance progress
- multilingual maintenance descriptions can be difficult to process consistently

HelaFixIt AI was developed to provide a structured maintenance workflow together with AI-assisted decision support.

---

## Project Aim

The main aim of HelaFixIt AI is to develop an apartment maintenance management system that can understand multilingual maintenance requests and assist apartment management staff with ticket prioritisation, risk identification and technician selection.

---

## Main Objectives

The system was developed to

1. provide an online maintenance ticket submission process for apartment residents
2. support English, Sinhala, Singlish and mixed-language maintenance descriptions
3. automatically predict the maintenance issue category
4. automatically predict ticket priority
5. calculate maintenance risk information
6. detect possible safety-related maintenance issues
7. identify possible duplicate maintenance requests
8. recommend suitable technicians
9. support emergency maintenance assignment
10. provide role-based workflows for residents, apartment administrators, technicians and system administrators
11. store ticket, user, AI and workflow information in a relational database
12. provide notifications, reports, audit information and system administration functions
13. keep the main AI prediction process locally within the project

---

# Main System Features

## Resident Functions

Residents can use the system to

- request registration for an apartment account
- sign in after account approval
- submit new maintenance tickets
- provide maintenance issue descriptions
- provide location and issue information
- upload supporting ticket files where applicable
- receive AI-assisted ticket analysis
- view predicted category and priority information
- view ticket details
- track maintenance ticket progress
- view notifications
- manage profile information

---

## Apartment Administrator Functions

Apartment administrators can

- view maintenance tickets belonging to their apartment environment
- review newly submitted maintenance requests
- review AI-generated ticket information
- check category, priority, risk and safety information
- review tickets requiring administrative attention
- assign technicians
- manage active maintenance jobs
- review emergency maintenance requests
- track maintenance progress
- review completed maintenance work
- manage resident registration requests
- access maintenance reports
- receive system notifications

---

## Technician Functions

Technicians can

- view assigned maintenance jobs
- view emergency jobs
- view maintenance ticket details
- review issue and location information
- update maintenance job status
- record repair notes
- manage work in progress
- submit completion information
- view notifications
- manage technician profile information

---

## System Administrator Functions

System administrators are responsible for higher-level system management.

Available administration functions include

- user management
- apartment and building management
- floor and maintenance area management
- role management
- issue category management
- technician skill management
- safety rule management
- resident registration management
- system settings
- maintenance mode
- audit log review
- system notifications
- account management
- reporting and administrative monitoring

---

# AI Decision Support Module

The AI module is one of the main components of HelaFixIt AI.

It processes maintenance descriptions submitted through the system and provides information that can assist apartment management staff when handling a ticket.

## Supported Languages

The maintenance dataset and AI validation process support

- English
- Sinhala
- Singlish
- Mixed-language maintenance text

---

## Training Dataset

The project contains a labelled multilingual apartment maintenance dataset.

The main file is

```text
AI-model/Data/maintenance_tickets.csv
```

The current dataset contains approximately 60,000 labelled maintenance ticket records.

Additional validation and challenge datasets are also included

```text
AI-model/Data/challenge_test.csv
AI-model/Data/language_validation_cases.csv
AI-model/Data/validation_cases.csv
```

The datasets are included in the repository so the AI development process can be reviewed and reproduced.

---

## AI Models

The system uses locally stored scikit-learn machine learning models.

The main saved model files are

```text
AI-model/Models/category_model.joblib
AI-model/Models/priority_model.joblib
AI-model/Models/tfidf_vectorizer.joblib
AI-model/Models/model_metadata.json
```

TF-IDF based text features are used by the trained category and priority classifiers.

The models are loaded by the Flask backend when AI ticket analysis is required.

---

## AI Decision Process

A maintenance ticket normally passes through the following AI-assisted process

1. the resident enters a maintenance description
2. the system processes the maintenance text
3. the language handling component analyses the submitted text
4. the category prediction model predicts the maintenance category
5. the priority model predicts the maintenance priority
6. safety rules are checked
7. a risk assessment is produced
8. possible duplicate ticket information is checked
9. technician suitability information is evaluated
10. the AI result is returned to the maintenance workflow
11. relevant prediction information is stored with the ticket
12. apartment management staff can review the result before continuing the maintenance process

The AI component is used as a decision-support mechanism rather than replacing the maintenance management workflow.

---

## Rule Files

Additional maintenance decision logic is stored separately from the trained models.

```text
AI-model/Rules/issue_rules.json
AI-model/Rules/risk_config.json
AI-model/Rules/safety_rules.json
AI-model/Rules/technician_rules.json
```

These files support issue handling, risk calculation, safety checking and technician recommendation logic.

---

# AI Training and Evaluation

The AI training source files are included in the repository.

```text
AI-model/Training/generate_dataset.py
AI-model/Training/train_models.py
AI-model/Training/evaluate_models.py
AI-model/Training/test_model_examples.py
AI-model/Training/validate_ai_cases.py
AI-model/Training/validate_language_recognition.py
```

The project also contains evaluation evidence generated from the AI validation process.

The `AI-model/Evaluation` folder includes items such as

- category classification reports
- priority classification reports
- category confusion matrices
- priority confusion matrices
- language recognition results
- language recognition confusion matrix
- accuracy by language
- model comparison results
- validation results
- misclassified examples
- evaluation summaries
- AI metrics

This provides evidence of the model training, testing and validation process rather than including only the final model files.

---

# Maintenance Ticket Workflow

A normal maintenance request follows this general workflow

```text
Resident
   |
   v
Submit Maintenance Ticket
   |
   v
Multilingual AI Analysis
   |
   +--> Category Prediction
   |
   +--> Priority Prediction
   |
   +--> Risk Assessment
   |
   +--> Safety Checking
   |
   +--> Duplicate Checking
   |
   +--> Technician Recommendation
   |
   v
Apartment Administrator Review
   |
   v
Technician Assignment
   |
   v
Assigned Job
   |
   v
Work In Progress
   |
   v
Repair and Status Updates
   |
   v
Completed Maintenance Job
   |
   v
Resident and Management Records Updated
```

Emergency maintenance requests can follow an accelerated assignment process depending on the maintenance condition and system rules.

---

# System Architecture

HelaFixIt AI uses a web-based multi-layer architecture.

```text
Web Browser
    |
    v
HTML / CSS / JavaScript Frontend
    |
    v
Flask REST API
    |
    +-----------------------+
    |                       |
    v                       v
Application Services     Local AI Module
    |                       |
    |                       +--> TF-IDF Vectorizer
    |                       +--> Category Model
    |                       +--> Priority Model
    |                       +--> Risk Rules
    |                       +--> Safety Rules
    |                       +--> Technician Rules
    |
    v
MariaDB Database
```

The Flask application also serves the frontend pages when the system is started locally.

---

# Technology Stack

| Area | Technologies |
| --- | --- |
| Frontend | HTML5, CSS3, JavaScript |
| Backend | Python, Flask |
| API | Flask REST endpoints |
| Authentication | Flask-JWT-Extended |
| Database | MariaDB / MySQL |
| Database connection | PyMySQL |
| Local AI | scikit-learn |
| Text processing | TF-IDF |
| Data processing | pandas, NumPy |
| Model storage | joblib |
| AI evaluation | matplotlib and generated evaluation files |
| Local development | XAMPP |
| Version control | Git and GitHub |

---

# Authentication and Security

The application uses role-based authentication and authorization.

JWT authentication is used by the Flask backend for protected application requests.

The backend also checks account state when validating authenticated sessions.

Security-related implementation includes

- password hashing
- role-based access control
- protected backend routes
- account status checking
- token validation
- revoked token checking
- input validation
- controlled runtime upload storage
- environment-based configuration
- separation of local secrets from repository source files

The local `.env` file is intentionally excluded from Git.

Production credentials should never be committed to the repository.

---

# Database

The database is implemented using MariaDB and is designed to store multilingual maintenance information using `utf8mb4`.

It contains data required for areas such as

- users
- user roles
- resident information
- technician information
- apartment complexes
- buildings
- floors
- maintenance areas
- issue categories
- maintenance tickets
- AI predictions
- ticket assignments
- ticket updates
- notifications
- registration requests
- system settings
- audit information
- authentication information
- maintenance workflow information

---

## Database Source Files

The modular database implementation is available through

```text
Database/01_create_database.sql
Database/02_schema.sql
Database/03_triggers.sql
Database/04_views.sql
Database/05_stored_procedures.sql
Database/06_seed_reference_data.sql
Database/07_seed_locations_users_and_indexes.sql
Database/08_validation_queries_XAMPP.sql
```

The complete clean setup source is

```text
Database/helafixit_ai_complete_setup.sql
```

The latest complete XAMPP database export containing the current project records is stored in

```text
Database/Full_Export/helafixit_ai_full_export.sql
```

Additional database documentation includes

```text
Database/database_dictionary.csv
Database/ERD.mmd
Database/README_DATABASE.md
Database/BACKUP_RESTORE_GUIDE.md
Database/XAMPP_DATABASE_SETUP.txt
Database/RUN_ORDER.txt
```

---

# Repository Structure

```text
HelaFixIt_AI
|
|-- AI-model
|   |-- Data
|   |-- Evaluation
|   |-- Models
|   |-- Rules
|   |-- Training
|   `-- README_AI.md
|
|-- Backend
|   |-- routes
|   |-- services
|   |-- uploads
|   |-- utils
|   |-- app.py
|   |-- config.py
|   |-- create_admin.py
|   |-- database.py
|   |-- requirements.txt
|   `-- .env.example
|
|-- Database
|   |-- Full_Export
|   |-- database source files
|   |-- database documentation
|   `-- database validation files
|
|
|-- Frontend
|   |-- Assets
|   |-- CSS
|   |-- JS
|   |-- Pages
|   `-- README_FRONTEND.txt
|
|-- .gitignore
|-- .gitattributes
`-- README.md
```

---

# How to Run HelaFixIt AI

The following instructions are intended for Windows and PowerShell using XAMPP.

## 1. Clone the Repository

```powershell
git clone https://github.com/rakindufernando/HelaFixIt_AI.git
Set-Location HelaFixIt_AI
```

If the project is already downloaded, open the project folder directly in VS Code.

```powershell
code .
```

---

## 2. Start XAMPP

Open XAMPP Control Panel.

Start

```text
MySQL
```

Apache may also be started if phpMyAdmin is being used.

---

## 3. Create the Database

Open phpMyAdmin in the browser.

For the current project database containing the complete project records, import

```text
Database/Full_Export/helafixit_ai_full_export.sql
```

For a clean database installation, use

```text
Database/helafixit_ai_complete_setup.sql
```

The clean setup file contains a password-hash placeholder for prepared accounts. Follow the instructions in

```text
Database/BACKUP_RESTORE_GUIDE.md
```

before importing the clean setup file.

After database creation, the validation script can be used

```text
Database/08_validation_queries_XAMPP.sql
```

---

## 4. Create the Backend Environment File

From the project root, copy the example environment file.

```powershell
Copy-Item "Backend\.env.example" "Backend\.env"
```

Open it in VS Code.

```powershell
code "Backend\.env"
```

Configure the local values as required.

Example development configuration

```text
APP_ENV=development
FLASK_DEBUG=1
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=root
DB_PASSWORD=
DB_NAME=helafixit_ai
JWT_SECRET_KEY=replace-with-a-long-random-development-key
JWT_ACCESS_HOURS=8
JWT_REFRESH_DAYS=7
DEFAULT_STAFF_PASSWORD=replace-with-a-temporary-password
```

Do not commit the completed `.env` file.

---

## 5. Create a Python Virtual Environment

From the project root run

```powershell
py -m venv Backend\venv
```

Activate it

```powershell
.\Backend\venv\Scripts\Activate.ps1
```

Upgrade pip

```powershell
python -m pip install --upgrade pip
```

---

## 6. Install Python Requirements

Run

```powershell
pip install -r Backend\requirements.txt
```

The backend requirements include Flask, JWT support, PyMySQL, scikit-learn, pandas, NumPy, joblib and the packages required by the AI evaluation process.

---

## 7. Run the Application

Move to the backend folder

```powershell
Set-Location Backend
```

Start Flask

```powershell
py app.py
```

The development server runs locally at

```text
http://127.0.0.1:5000
```

Open the address in a web browser.

The Flask application automatically redirects the root address to the HelaFixIt AI public landing page.

---

## 8. Check Backend, Database and AI Status

While the application is running, open another PowerShell terminal and run

```powershell
Invoke-RestMethod http://127.0.0.1:5000/api/health
```

The health response can confirm

- backend status
- database connection
- AI readiness
- application status

---

# Running the AI Files

The repository already contains the trained models, so model retraining is not required simply to run the website.

The following commands are provided for reproducing or reviewing the AI development process.

From the project root, activate the Python environment first.

```powershell
.\Backend\venv\Scripts\Activate.ps1
```

## Train the Models

```powershell
py "AI-model\Training\train_models.py"
```

## Evaluate the Models

```powershell
py "AI-model\Training\evaluate_models.py"
```

## Run AI Validation Cases

```powershell
py "AI-model\Training\validate_ai_cases.py"
```

## Validate Language Recognition

```powershell
py "AI-model\Training\validate_language_recognition.py"
```

## Test Representative Model Examples

```powershell
py "AI-model\Training\test_model_examples.py"
```

## Regenerate the Dataset

Only run the dataset generation script when the training dataset needs to be regenerated.

```powershell
py "AI-model\Training\generate_dataset.py"
```

The committed dataset and model files should be backed up before intentionally regenerating or retraining them if the existing assessment outputs need to be preserved.

---

# Frontend

The frontend is implemented using HTML, CSS and JavaScript.

It contains separate interfaces for

```text
Public pages
Resident pages
Apartment Admin pages
Technician pages
System Admin pages
```

The Flask application serves the frontend directly, so a separate frontend server is not required for normal local execution.

The frontend source is located in

```text
Frontend/
```

Additional frontend implementation information is available in

```text
Frontend/README_FRONTEND.txt
```

---

# Backend

The Flask backend contains routes and services for the main system functions.

Important route areas include

```text
Authentication
Roles
Residents
Apartment administrators
Technicians
AI
System administration
```

Important service areas include

```text
AI processing
Language processing
Authentication
Resident registration
Ticket management
Reporting
System settings
System administration
Maintenance workflow automation
```

The main application entry point is

```text
Backend/app.py
```

---

# Local AI and External Services

HelaFixIt AI does not require an external generative AI service for its main maintenance ticket predictions.

The category and priority models are stored locally and loaded by the Python backend.

This allows the repository to contain evidence of

- the dataset
- training source
- trained model files
- decision rules
- evaluation outputs
- integration source

instead of depending on an external AI API.

---

# Project Data

The repository contains the datasets and database records required to demonstrate the completed system.

The full database export is included to preserve the current project state for testing and assessment.

Runtime files such as local Python virtual environments, local environment configuration and normal uploaded ticket files are excluded from version control where appropriate.

---

# System Testing Support

The repository contains source and data that can be used to test

- user authentication
- role-based access
- resident registration
- maintenance ticket submission
- multilingual ticket analysis
- category prediction
- priority prediction
- risk assessment
- safety checking
- technician recommendation
- ticket assignment
- technician job updates
- notifications
- reports
- system administration
- database integration
- AI validation

AI-specific evaluation evidence is retained under

```text
AI-model/Evaluation
```

---

# Important Notes

- Start the XAMPP MySQL service before starting the Flask application.
- Confirm the database name is `helafixit_ai`.
- Create `Backend/.env` from `.env.example`.
- Replace example secrets and temporary passwords before using the application.
- Do not commit the local `.env` file.
- The trained AI models are already included.
- The main website can be opened through the Flask server on port 5000.
- The complete database export and clean setup source are both retained for different restoration requirements.
- The local Python virtual environment is intentionally excluded from GitHub.
- Core ticket prediction does not require an external AI API.

---

# Project Summary

HelaFixIt AI demonstrates how a conventional apartment maintenance management system can be combined with locally trained machine learning to support maintenance decision-making.

The final system integrates multilingual maintenance ticket submission, machine learning prediction, risk and safety analysis, technician recommendation, role-based maintenance workflows, database management, reporting, notifications and system administration within a single web application.

The repository contains the main implementation evidence required to understand and reproduce the project, including the frontend, backend, database source, complete database export, multilingual dataset, AI training scripts, saved models, rules and model evaluation outputs.
