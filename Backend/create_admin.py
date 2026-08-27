from getpass import getpass

from werkzeug.security import generate_password_hash

from app import app
from database import get_connection
from utils.validators import normalize_email, normalize_mobile, validate_email, validate_mobile, validate_name, validate_password


def main():
    print('Create initial HelaFixIt AI System Admin')
    name = input('Full name: ').strip()
    email = normalize_email(input('Email: '))
    phone = normalize_mobile(input('Mobile number: '))
    password = getpass('Password: ')
    confirm = getpass('Confirm password: ')

    if not validate_name(name):
        raise SystemExit('Enter a valid full name.')
    if not validate_email(email):
        raise SystemExit('Enter a valid email address.')
    if not validate_mobile(phone, required=True):
        raise SystemExit('Enter a valid Sri Lankan mobile number such as 0771234567 or +94771234567.')
    valid, message = validate_password(password)
    if not valid:
        raise SystemExit(message)
    if password != confirm:
        raise SystemExit('Passwords do not match.')

    with app.app_context():
        connection = get_connection()
        try:
            with connection.cursor() as cursor:
                cursor.execute('SELECT user_id FROM users WHERE LOWER(email)=%s LIMIT 1', (email,))
                if cursor.fetchone():
                    raise SystemExit('A user already exists with this email address.')
                cursor.execute("SELECT role_id FROM roles WHERE role_code='system_admin' AND active=TRUE LIMIT 1")
                role = cursor.fetchone()
                cursor.execute("SELECT complex_id FROM apartment_complexes WHERE status='Active' ORDER BY complex_id LIMIT 1")
                complex_row = cursor.fetchone()
                if not role or not complex_row:
                    raise SystemExit('Import the HelaFixIt AI database before creating the System Admin account.')
                cursor.execute(
                    """
                    INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,last_password_change_at,is_deleted)
                    VALUES(%s,%s,%s,%s,%s,%s,'Active',TRUE,FALSE,NOW(),FALSE)
                    """,
                    (role['role_id'],complex_row['complex_id'],name,email,phone,generate_password_hash(password, method='pbkdf2:sha256:600000')),
                )
                user_id = cursor.lastrowid
                cursor.execute('INSERT INTO notification_preferences(user_id) VALUES(%s)', (user_id,))
                cursor.execute("INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,reason) VALUES(%s,'SYSTEM_ADMIN_CREATED','User',%s,'Initial system administrator created')", (user_id,str(user_id)))
            connection.commit()
            print('System Admin account created successfully.')
        finally:
            connection.close()


if __name__ == '__main__':
    main()
