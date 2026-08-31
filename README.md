# HelaFixIt AI

**AI-Based Multilingual Apartment Maintenance Ticket Prioritization, Risk Scoring, and Technician Recommendation System**

HelaFixIt AI is a web-based apartment maintenance ticket management and AI decision support system. It allows residents to report maintenance issues and supports apartment administrators and technicians throughout the maintenance workflow. The system uses locally trained Python machine learning models together with rule-based logic to analyse multilingual maintenance tickets.

## Project Background

Apartment maintenance requests include issues such as plumbing leaks, electrical faults, lift problems, air conditioning faults, drainage blockages, cleaning issues, pest problems, damaged fittings, security problems and other building maintenance concerns.

In many apartment environments, maintenance complaints are handled through phone calls, messages, emails, paper forms or basic online forms. This can make the process slow and inconsistent when many requests are received. Urgent safety problems may not be recognised early, duplicate complaints may create repeated work, and selecting a suitable technician can take additional time.

This problem is more challenging in Sri Lanka because residents may describe maintenance issues using English, Sinhala, Singlish or mixed-language wording. HelaFixIt AI was developed to provide a structured ticket workflow together with multilingual AI-assisted decision support.

## Project Aim

The aim of this project is to develop an AI-based online maintenance ticket system that can understand multilingual apartment maintenance complaints, calculate risk, prioritise tickets and recommend suitable technicians using locally trained Python machine learning models.

## Main Objectives

- Develop a web-based platform that enables residents to submit apartment maintenance tickets through a simple form.
- Prepare a labelled maintenance ticket dataset using English, Sinhala, Singlish and mixed-language examples.
- Train local machine learning models to classify maintenance tickets into suitable issue categories and priority levels.
- Develop a context-aware risk scoring method using priority, safety terms, issue category, location, duplicate reports and ticket history.
- Recommend a suitable technician based on the predicted issue, risk level, technician skills, availability and workload.
- Evaluate the AI module and system using classification metrics, confusion matrices, scenario testing and system testing.

# Main System Features

HelaFixIt AI contains four main user roles and a complete maintenance ticket workflow.

- Resident
- Apartment Administrator
- Technician
- System Administrator

The system includes multilingual ticket submission, category and priority prediction, risk scoring, safety detection, duplicate detection, technician recommendation, emergency assignment support, notifications, reporting and audit records.

## Resident Functions

Residents can

- request a resident account and wait for administrator approval
- sign in to the resident portal
- submit maintenance tickets using a simple web form
- enter the issue title, description, building, floor, area and asset information
- upload an optional maintenance issue image
- receive AI-assisted ticket analysis
- view predicted category, priority, risk and safety information
- view possible duplicate information
- track submitted maintenance tickets and their current status
- view assigned technician information when available
- receive notifications
- manage profile information
- request password reset assistance

## Apartment Administrator Functions

Apartment Administrators can

- manage maintenance requests for their assigned building
- review newly submitted tickets
- review AI-generated category, priority, risk, safety and duplicate results
- view resident issue images
- review tickets that require manual attention
- assign suitable technicians
- review technician recommendations
- monitor emergency and urgent maintenance tickets
- manage active jobs and ticket progress
- review completed maintenance work
- review and approve or reject resident registration requests for their building
- view notifications and maintenance reports

## Technician Functions

Technicians can

- view jobs assigned to them
- view maintenance ticket and location details
- view resident issue images for assigned jobs
- accept and manage assigned maintenance work
- update job status
- add repair and progress notes
- manage jobs that are in progress or on hold
- add completion information
- view notifications
- manage technician profile information

## System Administrator Functions

System Administrators can

- manage users and user accounts
- manage resident registration requests
- manage apartment complexes, buildings, floors, areas and units
- manage issue categories and technician skills
- manage safety rules and system reference information
- reset user passwords using temporary passwords
- manage system settings
- enable or disable maintenance mode
- review audit logs
- monitor notifications and system activity
- access administrative reports and system information

# AI Decision Support Module

The AI Decision Support Module analyses maintenance tickets before they continue through the normal maintenance workflow.

For each analysed ticket, the system can provide

- predicted maintenance category
- predicted priority
- category and priority confidence
- risk score from 0 to 100
- risk level
- safety warning
- possible duplicate result
- recommended technician or technician skill
- emergency assignment decision where applicable

The AI output supports maintenance decisions. Apartment Administrators can still review the ticket and manage the final maintenance workflow.

## Supported Languages

The system supports maintenance descriptions written in

- English
- Sinhala
- Singlish
- Mixed-language text

Singlish refers to Sinhala wording written using Latin characters.

## Training Dataset

The main training dataset is

```text
AI-model/Data/maintenance_tickets.csv
```

The current dataset contains **60,000 labelled maintenance ticket records** covering multilingual apartment maintenance scenarios.

The repository also contains additional validation and challenge data such as

```text
AI-model/Data/challenge_test.csv
AI-model/Data/language_validation_cases.csv
AI-model/Data/validation_cases.csv
```

The dataset contains examples for maintenance categories, priority levels and multilingual ticket descriptions used to train and evaluate the local AI models.

## Dataset Sources and References

The HelaFixIt AI training dataset was created specifically for this final development project. The 60,000 labelled maintenance ticket records were generated using project-defined apartment maintenance scenarios and multilingual wording variations.

Academic research papers were used to support the apartment maintenance domain, priority handling, Sinhala-English mixed text, and Singlish wording used when preparing the dataset. Official technical documentation was used to support the machine learning methods used to train and evaluate the AI models.

The complete list of supporting academic and technical references is available here

[Training Dataset References](AI-model/DATASET_REFERENCES.md)

## AI Models

The implemented AI models use scikit-learn and TF-IDF text features.

The current model bundle uses

- word and character TF-IDF text features
- SGDClassifier with logistic loss for category prediction
- SGDClassifier with logistic loss for priority prediction
- rule-based safety detection
- rule-based and contextual risk scoring
- text similarity for duplicate detection
- skill, availability and workload based technician recommendation

The main saved model files are

```text
AI-model/Models/category_model.joblib
AI-model/Models/priority_model.joblib
AI-model/Models/tfidf_vectorizer.joblib
AI-model/Models/model_metadata.json
```

The current saved model metadata identifies the model bundle as version `6.0.0`.

## AI Decision Process

The main AI decision process is

```text
Resident submits ticket
        |
        v
Validate and process ticket text
        |
        v
Detect language and prepare text
        |
        v
TF-IDF feature extraction
        |
        +--> Category prediction
        |
        +--> Priority prediction
        |
        v
Safety rule checking
        |
        v
Duplicate ticket checking
        |
        v
Risk score calculation
        |
        v
Technician recommendation
        |
        v
Store AI result
        |
        v
Administrator review or emergency workflow
```

Emergency or critical tickets can be automatically assigned to a suitable available technician when the system rules allow it. If a suitable technician is not available, the ticket remains available for urgent administrator attention.

Possible duplicate tickets are kept in the system and linked through duplicate detection information. They are not automatically deleted.

# AI Training and Evaluation

The repository contains the scripts used to prepare, train, test and evaluate the AI module.

```text
AI-model/Training/generate_dataset.py
AI-model/Training/train_models.py
AI-model/Training/evaluate_models.py
AI-model/Training/test_model_examples.py
AI-model/Training/validate_ai_cases.py
AI-model/Training/validate_language_recognition.py
```

The evaluation process includes

- category classification evaluation
- priority classification evaluation
- accuracy, precision, recall and F1 score
- confusion matrices
- grouped holdout testing
- challenge-case testing
- multilingual language recognition validation
- scenario-based AI validation
- review of misclassified examples

Generated evaluation evidence is stored in

```text
AI-model/Evaluation
```

The trained models are already included in the repository, so retraining is not required simply to run the HelaFixIt AI web application.

# Maintenance Ticket Workflow

The normal maintenance workflow is

```text
Resident registration and login
        |
        v
Submit maintenance ticket
        |
        v
AI ticket analysis
        |
        v
Category, priority, risk and safety result
        |
        v
Duplicate checking and technician recommendation
        |
        v
Apartment Administrator review
        |
        v
Technician assignment
        |
        v
Technician accepts and updates job
        |
        v
Work in progress
        |
        v
Repair completed
        |
        v
Ticket and workflow records updated
```

Emergency or critical tickets can use the emergency assignment workflow when a suitable technician is available. Notifications and ticket updates are recorded throughout the maintenance process.

# System Architecture

HelaFixIt AI uses a layered web application architecture.

```text
Resident / Apartment Administrator / Technician / System Administrator
                              |
                              v
                         Web Browser
                              |
                              v
                   HTML / CSS / JavaScript
                              |
                              v
                     Python Flask Backend
                              |
             +----------------+----------------+
             |                                 |
             v                                 v
     Application Services              Local AI Module
             |                    TF-IDF and ML Models
             |                    Safety and Risk Rules
             |                    Duplicate Detection
             |                    Technician Recommendation
             |                                 |
             +----------------+----------------+
                              |
                              v
                    MariaDB / MySQL Database
                              |
                 +------------+------------+
                 |                         |
                 v                         v
          AI Model Files           Runtime Upload Files
```

The core ticket prediction and risk analysis are performed locally by the Flask application and saved AI model files. The implemented core system does not require an external generative AI service.

# Technology Stack

| Area | Technology |
| --- | --- |
| Frontend | HTML5, CSS3, JavaScript |
| Backend | Python, Flask |
| Authentication | Flask-JWT-Extended |
| Database | MariaDB / MySQL |
| Database Connection | PyMySQL |
| Machine Learning | scikit-learn |
| Text Features | TF-IDF |
| Data Processing | pandas, NumPy |
| Model Storage | joblib |
| Evaluation | matplotlib |
| Local Development | XAMPP |
| Version Control | Git and GitHub |

# Authentication and Security

HelaFixIt AI uses role-based authentication and access control.

The implemented security features include

- JWT-based authentication
- password hashing
- role-based protected backend routes
- account-status checking
- access checks based on user role
- token validation and revoked-token handling
- input validation
- controlled image upload handling
- environment-based configuration
- local secret values stored outside the repository

The local `Backend/.env` file is excluded from Git. Sensitive values such as the JWT secret and temporary staff password must be configured locally.

Residents access their own maintenance information, Apartment Administrators manage their assigned building, and Technicians access jobs assigned to them.

# Database

HelaFixIt AI uses a MariaDB / MySQL relational database named

```text
helafixit_ai
```

The database uses `utf8mb4` to support multilingual maintenance text.

The database stores information including

- users, roles and role permissions
- resident, apartment administrator and technician profiles
- apartment complexes, buildings, floors, areas and units
- resident registration requests
- maintenance tickets
- issue categories and technician skills
- AI predictions
- duplicate ticket matches
- technician assignments
- ticket status updates
- notifications and notification preferences
- system settings
- login and authentication records
- audit logs

Database source, setup and export files are stored inside the `Database` folder.

# How to Run HelaFixIt AI

1. Download the repository as a ZIP from GitHub or clone it.

```powershell
git clone https://github.com/rakindufernando/HelaFixIt_AI.git
cd HelaFixIt_AI
```

2. Open XAMPP and start **MySQL**. Start **Apache** as well if phpMyAdmin is required.

3. Import the provided HelaFixIt AI database SQL file into phpMyAdmin using the database files in the `Database` folder.

4. Create the local backend environment file.

```powershell
Copy-Item "Backend\.env.example" "Backend\.env"
```

Open `Backend/.env` and enter the local database settings, JWT secret and temporary staff password.

5. Create a Python environment and install the required packages.

```powershell
py -m venv Backend\venv
.\Backend\venv\Scripts\Activate.ps1
pip install -r Backend\requirements.txt
```

6. Run the Flask application.

```powershell
cd Backend
py app.py
```

7. Open the system in a web browser.

```text
http://127.0.0.1:5000
```

The trained AI models are already included in the repository.

# Project Data

The repository includes the main data and evidence required for the project.

```text
AI-model/Data
AI-model/Models
AI-model/Rules
AI-model/Training
AI-model/Evaluation
Database
Backend
Frontend
```

The project data includes

- 60,000 labelled multilingual maintenance ticket records
- AI validation and challenge datasets
- trained category and priority models
- model metadata
- risk, safety, issue and technician rule files
- AI evaluation outputs
- database schema and project database data
- maintenance ticket and workflow records
- user-role and apartment reference data
- source code for the frontend and backend

The database and AI dataset contain prepared project and testing data. They should not be treated as live operational apartment records.

# Important Notes

- HelaFixIt AI is a web-based maintenance system with local AI decision support.
- The core AI process does not require an external AI prediction API.
- AI results support maintenance decisions and do not remove administrator review from the workflow.
- The current scope supports one apartment complex containing multiple buildings or blocks, floors, areas and units.
- Duplicate maintenance tickets are retained and linked when the system identifies a possible duplicate.
- Ticket issue images are stored as runtime upload files under the backend upload folder and are not intended to be committed as normal repository source files.
- The trained models are already included, so model retraining is optional when running the system.
- AI accuracy depends on the prepared training data and the wording of real maintenance requests.
- External services such as SMS, cloud storage, maps or other integrations are not required for the implemented core workflow.

# Project Summary

HelaFixIt AI combines apartment maintenance ticket management with multilingual machine learning and rule-based decision support. Residents can submit maintenance problems through a web interface, the system analyses each ticket, and Apartment Administrators can use the generated category, priority, risk, safety, duplicate and technician information when managing the maintenance process.

The final system connects four user roles, a Flask backend, a MariaDB database and locally stored scikit-learn models. It provides a complete workflow from resident ticket submission to technician assignment, progress updates and maintenance completion while keeping AI decisions explainable and reviewable.
