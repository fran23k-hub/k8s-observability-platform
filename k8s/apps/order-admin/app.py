from flask import Flask, jsonify, request, render_template
import time
import os
from psycopg2.extras import RealDictCursor
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST
from vault_db import get_connection, release_connection, init_pool

app = Flask(__name__)

POD_NAME = os.getenv("HOSTNAME", "unknown")
START_TIME = int(time.time())

# ----------------------------
# DATABASE — Vault credentials
# ----------------------------
# vault_db.py handles reading /vault/secrets/db-creds,
# connection pooling, and automatic pool refresh when
# Vault rotates credentials. No manual reconnection needed.
# ----------------------------

try:
    init_pool()
except Exception as e:
    print(f"Pool init skipped (Vault not ready yet): {e}")


# ----------------------------
# ADMIN FRONTEND
# ----------------------------

@app.route("/")
def home():
    return render_template("admin.html", pod_name=POD_NAME, start_time=START_TIME)


# ----------------------------
# ADMIN API
# ----------------------------

@app.route("/metrics-summary")
def metrics_summary():

    conn = get_connection()
    cur = conn.cursor()

    cur.execute("SELECT COUNT(*) FROM orders;")
    total = cur.fetchone()[0]

    cur.execute("SELECT AVG(processing_time) FROM orders;")
    avg = cur.fetchone()[0] or 0

    cur.execute("SELECT COUNT(*) FROM orders WHERE processed_by=%s;", (POD_NAME,))
    pod_count = cur.fetchone()[0]

    cur.close()
    release_connection(conn)

    return jsonify({
        "total_orders": total,
        "avg_processing_time": round(avg, 3),
        "orders_this_pod": pod_count
    })


@app.route("/orders")
def get_orders():

    limit = int(request.args.get("limit", 100))
    offset = int(request.args.get("offset", 0))

    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    cur.execute("""
    SELECT o.id,
           o.email,
           p.name AS product_name,
           o.quantity,
           o.build_config,
           o.total_price,
           o.processing_time,
           o.processed_by,
           o.created_at
    FROM orders o
    LEFT JOIN products p ON o.product_id=p.id
    ORDER BY o.id DESC
    LIMIT %s OFFSET %s
    """, (limit, offset))

    rows = cur.fetchall()

    cur.close()
    release_connection(conn)

    results = []

    for row in rows:

        if row["build_config"]:
            order_type = "PC BUILD"
            product_display = "Custom PC Build"
            quantity = "-"
        else:
            order_type = "SIMPLE"
            product_display = row["product_name"]
            quantity = row["quantity"]

        results.append({
            "id": row["id"],
            "email": row["email"],
            "order_type": order_type,
            "product": product_display,
            "quantity": quantity,
            "build_config": row["build_config"],
            "total_price": float(row["total_price"]) if row["total_price"] else None,
            "processing_time_seconds": round(row["processing_time"] or 0, 3),
            "processed_by_pod": row["processed_by"],
            "created_at": str(row["created_at"])
        })

    return jsonify(results)


@app.route("/order/<int:order_id>", methods=["DELETE"])
def delete_order(order_id):

    conn = get_connection()
    cur = conn.cursor()

    cur.execute("DELETE FROM orders WHERE id=%s", (order_id,))
    conn.commit()

    cur.close()
    release_connection(conn)

    return jsonify({"deleted": order_id})


@app.route("/health")
def health():
    return jsonify({"status": "healthy"}), 200


@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
