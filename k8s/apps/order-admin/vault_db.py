"""
vault_db.py
-----------
Reusable Vault dynamic credential helper for Flask services.

Drop this file into any new service that uses Vault Agent Injector
for dynamic PostgreSQL credentials.

Usage in your app.py:
    from vault_db import get_connection, release_connection, init_pool

The Vault Agent sidecar writes credentials to /vault/secrets/db-creds
in this format:
    DB_USER=v-kubernet-my-service-r-xxxxx
    DB_PASSWORD=generatedpassword

Your deployment must have DB_HOST and DB_NAME set as environment variables.
DB_USER and DB_PASSWORD are handled entirely by this module — do not set them
as environment variables.
"""

import os
import threading
import psycopg2
from psycopg2.pool import SimpleConnectionPool

# Path where Vault Agent sidecar writes dynamic credentials
VAULT_CREDS_FILE = "/vault/secrets/db-creds"

_db_pool = None
_db_pool_lock = threading.Lock()


# ------------------------------------------------------------------
# Internal helpers
# ------------------------------------------------------------------

def _read_vault_creds():
    """
    Read dynamic username and password from the Vault Agent injected file.
    Raises RuntimeError if the file is missing (Vault sidecar not ready).
    """
    creds = {}
    try:
        with open(VAULT_CREDS_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if "=" in line:
                    key, _, value = line.partition("=")
                    creds[key.strip()] = value.strip()
    except FileNotFoundError:
        raise RuntimeError(
            f"Vault credentials file not found at {VAULT_CREDS_FILE}. "
            "Is the Vault Agent sidecar running? Check: kubectl get pods"
        )
    return creds


def _build_db_config():
    """
    Combine static config from environment variables (host, db name)
    with dynamic credentials from the Vault file (user, password).
    """
    creds = _read_vault_creds()
    return {
        "host":     os.getenv("DB_HOST", "postgres.default.svc.cluster.local"),
        "database": os.getenv("DB_NAME", "ordersdb"),
        "user":     creds.get("DB_USER"),
        "password": creds.get("DB_PASSWORD"),
    }


# ------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------

def init_pool(minconn=2, maxconn=20):
    """
    Explicitly initialise the connection pool.
    Optional — the pool is also created lazily on first get_connection() call.
    Call this at app startup if you want to fail fast on bad credentials.
    """
    global _db_pool
    with _db_pool_lock:
        config = _build_db_config()
        _db_pool = SimpleConnectionPool(minconn=minconn, maxconn=maxconn, **config)
    print("[vault_db] Connection pool initialised.")


def refresh_pool(minconn=2, maxconn=20):
    """
    Close the existing pool and open a new one with fresh Vault credentials.

    Called automatically by get_connection() when a psycopg2.OperationalError
    is raised — this typically means credentials have been rotated by Vault
    and the old username/password are no longer valid.

    You can also call this manually if needed.
    """
    global _db_pool
    with _db_pool_lock:
        if _db_pool is not None:
            try:
                _db_pool.closeall()
            except Exception:
                pass
        config = _build_db_config()
        _db_pool = SimpleConnectionPool(minconn=minconn, maxconn=maxconn, **config)
    print("[vault_db] Connection pool refreshed with new Vault credentials.")


def _get_pool():
    """Return the current pool, creating it lazily if not yet initialised."""
    global _db_pool
    if _db_pool is None:
        with _db_pool_lock:
            if _db_pool is None:
                config = _build_db_config()
                _db_pool = SimpleConnectionPool(minconn=2, maxconn=20, **config)
    return _db_pool


def get_connection():
    """
    Get a connection from the pool.

    If a psycopg2.OperationalError is raised (credentials rotated),
    the pool is refreshed once automatically and the connection is retried.
    """
    try:
        from psycopg2.pool import PoolError
        conn = _get_pool().getconn()
        conn.cursor().execute("SELECT 1")
        return conn
    except (psycopg2.OperationalError, PoolError, AttributeError):
        print("[vault_db] Pool dead or credentials rotated. Refreshing pool.")
        refresh_pool()
        return _get_pool().getconn()

def release_connection(conn):
    """Return a connection back to the pool. Always call this after get_connection()."""
    try:
        _get_pool().putconn(conn)
    except Exception as e:
        print(f"[vault_db] Warning: could not return connection to pool: {e}")
