from pathlib import Path

from flask import Flask, jsonify, redirect, send_from_directory
from flask_cors import CORS
from flask_jwt_extended import JWTManager

from config import Config
from database import query_one, test_connection
from routes.auth_routes import auth_bp
from routes.role_routes import role_bp
from routes.resident_routes import resident_bp
from routes.admin_routes import admin_bp
from routes.technician_routes import technician_bp
from routes.ai_routes import ai_bp
from routes.system_admin_routes import system_admin_bp

jwt = JWTManager()


def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)

    jwt.init_app(app)
    CORS(
        app,
        resources={r"/api/*": {"origins": app.config['CORS_ORIGINS']}},
        supports_credentials=False,
    )

    app.register_blueprint(auth_bp)
    app.register_blueprint(role_bp)
    app.register_blueprint(resident_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(technician_bp)
    app.register_blueprint(ai_bp)
    app.register_blueprint(system_admin_bp)

    Path(app.config['UPLOAD_FOLDER']).mkdir(parents=True, exist_ok=True)

    @jwt.token_in_blocklist_loader
    def is_token_revoked(jwt_header, jwt_payload):
        jti = jwt_payload.get('jti')
        user_id = jwt_payload.get('sub')
        issued_at = jwt_payload.get('iat')
        if not jti or not user_id:
            return True
        try:
            revoked = query_one('SELECT revoked_token_id FROM revoked_tokens WHERE token_jti = %s LIMIT 1', (jti,))
            if revoked:
                return True
            user = query_one(
                "SELECT account_status,is_deleted,auth_version FROM users WHERE user_id=%s LIMIT 1",
                (int(user_id),),
            )
            if not user or user.get('is_deleted') or user.get('account_status') != 'Active':
                return True
            if int(user.get('auth_version') or 1) != int(jwt_payload.get('auth_version') or 1):
                return True
            return False
        except Exception:
            # Protected requests fail closed if the account state cannot be verified.
            return True

    @jwt.unauthorized_loader
    def missing_token(reason):
        return jsonify({'success': False, 'message': 'Authentication token is required.'}), 401

    @jwt.invalid_token_loader
    def invalid_token(reason):
        return jsonify({'success': False, 'message': 'Authentication token is invalid.'}), 401

    @jwt.expired_token_loader
    def expired_token(jwt_header, jwt_payload):
        return jsonify({'success': False, 'message': 'Your login session has expired. Please sign in again.'}), 401

    @jwt.revoked_token_loader
    def revoked_token(jwt_header, jwt_payload):
        return jsonify({'success': False, 'message': 'This login session has been signed out.'}), 401

    @app.get('/api/health')
    def health():
        connected, details = test_connection()
        status = 200 if connected else 503
        ai = {'ready': False}
        try:
            from services.ai_service import ai_status
            ai = ai_status()
        except Exception as exc:
            ai = {'ready': False, 'error': str(exc)}
        try:
            from services.settings_service import get_string_setting
            application_name = get_string_setting('system_name', 'HelaFixIt AI') if connected else 'HelaFixIt AI'
        except Exception:
            application_name = 'HelaFixIt AI'
        return jsonify({
            'success': connected,
            'application': application_name,
            'backend': 'running',
            'database': 'connected' if connected else 'disconnected',
            'ai': ai,
            'details': details,
        }), status

    @app.errorhandler(404)
    def not_found(error):
        if str(getattr(error, 'description', '')).startswith('/api'):
            return jsonify({'success': False, 'message': 'API endpoint not found.'}), 404
        return jsonify({'success': False, 'message': 'Resource not found.'}), 404

    @app.errorhandler(413)
    def too_large(error):
        return jsonify({'success': False, 'message': 'The uploaded file is too large.'}), 413

    @app.errorhandler(Exception)
    def unhandled_exception(error):
        app.logger.exception('Unhandled application error')
        if app.config.get('DEBUG'):
            return jsonify({'success': False, 'message': str(error)}), 500
        return jsonify({'success': False, 'message': 'An unexpected server error occurred.'}), 500

    frontend_dir = Path(app.config['FRONTEND_DIR'])

    @app.get('/')
    def frontend_home():
        return redirect('/Pages/Public%20pages/index.html')

    @app.get('/<path:filename>')
    def frontend_files(filename):
        if filename.startswith('api/'):
            return jsonify({'success': False, 'message': 'API endpoint not found.'}), 404
        target = frontend_dir / filename
        if target.is_file():
            return send_from_directory(frontend_dir, filename)
        return jsonify({'success': False, 'message': 'Frontend file not found.'}), 404

    return app


app = create_app()

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000, debug=app.config['DEBUG'])
