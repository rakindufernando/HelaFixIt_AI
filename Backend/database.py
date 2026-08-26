import pymysql
from flask import current_app


def get_connection(autocommit=False):
    return pymysql.connect(
        host=current_app.config['DB_HOST'],
        port=current_app.config['DB_PORT'],
        user=current_app.config['DB_USER'],
        password=current_app.config['DB_PASSWORD'],
        database=current_app.config['DB_NAME'],
        charset='utf8mb4',
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=autocommit,
    )


def query_one(sql, params=None):
    connection = get_connection(autocommit=True)
    try:
        with connection.cursor() as cursor:
            cursor.execute(sql, params or ())
            return cursor.fetchone()
    finally:
        connection.close()


def query_all(sql, params=None):
    connection = get_connection(autocommit=True)
    try:
        with connection.cursor() as cursor:
            cursor.execute(sql, params or ())
            return cursor.fetchall()
    finally:
        connection.close()


def test_connection():
    try:
        row = query_one('SELECT DATABASE() AS database_name, VERSION() AS server_version')
        return True, row
    except Exception as exc:
        return False, {'error': str(exc)}
