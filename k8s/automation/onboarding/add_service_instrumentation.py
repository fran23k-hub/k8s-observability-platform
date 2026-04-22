#!/usr/bin/env python3
"""
add_service_instrumentation.py

Patches app.py with the required endpoints and imports for onboarding
a new service into the Kubernetes Monitoring Platform.

Usage:
  # Service without database:
  python3 add_service_instrumentation.py ~/k8s/my-service/

  # Service with database (Vault dynamic credentials):
  python3 add_service_instrumentation.py ~/k8s/my-service/ --vault

What gets added:
  Always:
    - prometheus_client import
    - /health endpoint
    - /metrics endpoint (real Prometheus format)

  With --vault:
    - vault_db import line
    - Checks vault_db.py is present in the folder before proceeding

  Also checks:
    - prometheus_client is in requirements.txt
    - psycopg2-binary is in requirements.txt (--vault only)
"""

import os
import sys

VAULT_IMPORT = "from vault_db import get_connection, release_connection, init_pool"
PROMETHEUS_IMPORT = "from prometheus_client import generate_latest, CONTENT_TYPE_LATEST"

HEALTH_ENDPOINT = """
@app.route("/health")
def health():
    return {"status": "ok"}, 200
"""

METRICS_ENDPOINT = """
@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}
"""


def check_requirements(service_dir, vault=False):
    req_file = os.path.join(service_dir, "requirements.txt")
    warnings = []

    if not os.path.exists(req_file):
        warnings.append("requirements.txt not found — create it before building")
        return warnings

    with open(req_file, "r") as f:
        contents = f.read()

    if "prometheus_client" not in contents:
        warnings.append("prometheus_client is missing from requirements.txt — add it or the /metrics endpoint will fail at runtime")

    if vault and "psycopg2" not in contents and "psycopg2-binary" not in contents:
        warnings.append("psycopg2-binary is missing from requirements.txt — add it or database connections will fail at runtime")

    return warnings


def patch_file(filepath, vault=False):
    with open(filepath, "r") as f:
        content = f.read()

    changed = False

    # Add vault_db import if --vault and missing
    if vault and VAULT_IMPORT not in content:
        content = VAULT_IMPORT + "\n" + content
        changed = True

    # Add prometheus_client import if missing
    if PROMETHEUS_IMPORT not in content:
        content = PROMETHEUS_IMPORT + "\n" + content
        changed = True

    # Add /health endpoint if missing
    if '@app.route("/health")' not in content:
        content += "\n" + HEALTH_ENDPOINT
        changed = True

    # Add /metrics endpoint if missing
    if '@app.route("/metrics")' not in content:
        content += "\n" + METRICS_ENDPOINT
        changed = True

    if changed:
        with open(filepath, "w") as f:
            f.write(content)
        print(f"Patched: {filepath}")
    else:
        print(f"No changes needed: {filepath}")


def main():
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 add_service_instrumentation.py <service-folder>")
        print("  python3 add_service_instrumentation.py <service-folder> --vault")
        print("")
        print("Examples:")
        print("  python3 add_service_instrumentation.py ~/k8s/my-service/")
        print("  python3 add_service_instrumentation.py ~/k8s/my-service/ --vault")
        sys.exit(1)

    service_dir = sys.argv[1]
    vault = "--vault" in sys.argv

    app_file = os.path.join(service_dir, "app.py")
    vault_db_file = os.path.join(service_dir, "vault_db.py")

    if not os.path.exists(app_file):
        print(f"Error: app.py not found in {service_dir}")
        sys.exit(1)

    if vault and not os.path.exists(vault_db_file):
        print(f"Error: vault_db.py not found in {service_dir}")
        print(f"Copy it first: cp ~/k8s/onboarding/vault_db.py {service_dir}")
        sys.exit(1)

    print(f"Service folder : {service_dir}")
    print(f"Vault mode     : {'yes' if vault else 'no'}")
    print("")

    # Check requirements.txt before patching
    warnings = check_requirements(service_dir, vault=vault)
    if warnings:
        print("Warnings:")
        for w in warnings:
            print(f"  [!] {w}")
        print("")

    patch_file(app_file, vault=vault)


if __name__ == "__main__":
    main()
