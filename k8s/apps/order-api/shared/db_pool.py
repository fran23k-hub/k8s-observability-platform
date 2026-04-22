import os
import threading
import psycopg2
from psycopg2 import pool
from psycopg2.pool import PoolError

db_pool = None
_lock = threading.Lock()

def load_db_creds():
    creds = {}
    with open("/vault/secrets/db-creds", "r") as f:
        for line in f:
            line = line.strip()
            if "=" in line:
                key, _, value = line.partition("=")
                creds[key.strip()] = value.strip()
    return creds

def create_new_pool():
    global db_pool
    with _lock:
        creds = load_db_creds()
        if db_pool is not None:
            try:
                db_pool.closeall()
            except Exception:
                pass
        db_pool = pool.SimpleConnectionPool(
            2, 20,
            host=os.getenv("DB_HOST", "postgres.default.svc.cluster.local"),
            database=os.getenv("DB_NAME", "ordersdb"),
            user=creds.get("DB_USER"),
            password=creds.get("DB_PASSWORD"),
        )
    print("DB pool created/refreshed.")

def get_connection():
    global db_pool
    try:
        conn = db_pool.getconn()
        conn.cursor().execute("SELECT 1")
        return conn
    except (PoolError, psycopg2.OperationalError, AttributeError):
        print("Pool dead → rebuilding")
        create_new_pool()
        return db_pool.getconn()

def release_connection(conn):
    global db_pool
    if db_pool and conn:
        db_pool.putconn(conn)
