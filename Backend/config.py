import os
from datetime import timedelta
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv()
except Exception:
    pass


class Config:
    APP_ENV = os.getenv('APP_ENV', 'development')
    DEBUG = os.getenv('FLASK_DEBUG', '1') == '1'

    DB_HOST = os.getenv('DB_HOST', '127.0.0.1')
    DB_PORT = int(os.getenv('DB_PORT', '3306'))
    DB_USER = os.getenv('DB_USER', 'root')
    DB_PASSWORD = os.getenv('DB_PASSWORD', '')
    DB_NAME = os.getenv('DB_NAME', 'helafixit_ai')

    DEFAULT_STAFF_PASSWORD = os.getenv('DEFAULT_STAFF_PASSWORD', 'helafixit@321')

    JWT_SECRET_KEY = os.getenv('JWT_SECRET_KEY', 'helafixit-student-development-key-change-before-deployment')
    JWT_ACCESS_TOKEN_EXPIRES = timedelta(hours=int(os.getenv('JWT_ACCESS_HOURS', '8')))
    JWT_REFRESH_TOKEN_EXPIRES = timedelta(days=int(os.getenv('JWT_REFRESH_DAYS', '7')))

    MAX_CONTENT_LENGTH = 20 * 1024 * 1024
    FRONTEND_DIR = Path(__file__).resolve().parent.parent / 'Frontend'
    UPLOAD_FOLDER = Path(__file__).resolve().parent / 'uploads'
    AI_ROOT = Path(__file__).resolve().parent.parent / 'AI-model'

    # Local frontend origins. The app can also serve the frontend itself on port 5000.
    CORS_ORIGINS = [
        'http://127.0.0.1:5000',
        'http://localhost:5000',
        'http://127.0.0.1:5500',
        'http://localhost:5500',
    ]
