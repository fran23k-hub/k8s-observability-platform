from flask import Flask, jsonify, request, render_template, redirect
import os
import json
import psycopg2
import redis
import time
import random

from psycopg2.extras import RealDictCursor
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from shared.db_pool import get_connection, create_new_pool, release_connection

USE_CACHE = os.getenv("USE_CACHE", "true").lower() == "true"
SIMULATE_BOTTLENECK = os.getenv("SIMULATE_BOTTLENECK", "false").lower() == "true"

app = Flask(__name__)
POD_NAME = os.getenv("HOSTNAME", "unknown")

# --------------------------------
# PROMETHEUS METRICS
# --------------------------------

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP Requests",
    ["app", "method", "endpoint", "status"]
)

REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency"
)

# --------------------------------
# BOTTLENECK HELPERS
# --------------------------------

def simulate_stress():
    """
    Phase 1 — latency buildup.
    Reduced range (0.05-0.2s) causes queue buildup and CPU pressure
    without triggering a sudden backlog that bursts straight to 5 pods.
    """
    time.sleep(random.uniform(0.05, 0.2))


def should_fail():
    """
    Phase 2 — tighter, less chaotic failure band.
    Range: 0.4% - 1.0% (keeps close to the 99.5% SLO line)
    """
    failure_chance = 0.004 + random.uniform(0, 0.006)
    return random.random() < failure_chance

# --------------------------------
# REQUEST METRICS MIDDLEWARE
# --------------------------------

@app.before_request
def start_timer():
    request.start_time = time.time()
    print(f"{request.method} {request.path} from {request.remote_addr}")

@app.after_request
def record_metrics(response):
    request_latency = time.time() - request.start_time
    REQUEST_LATENCY.observe(request_latency)

    REQUEST_COUNT.labels(
        "order-api",
        request.method,
        request.path,
        str(response.status_code)
    ).inc()

    return response

# --------------------------------
# REDIS CONFIG
# --------------------------------

redis_client = redis.Redis(
    host="redis",
    port=6379,
    decode_responses=True
)

# --------------------------------
# CACHE HELPERS
# --------------------------------

def get_product_by_id(product_id):
    cache_key = f"product:{product_id}"

    if USE_CACHE:
        cached = redis_client.get(cache_key)
        if cached:
            return json.loads(cached)

    conn = get_connection()
    cur = conn.cursor()
    cur.execute("SELECT id, name, price FROM products WHERE id=%s;", (product_id,))
    result = cur.fetchone()
    cur.close()
    release_connection(conn)

    if result:
        pid, name, price = result
        product_data = {
            "id": pid,
            "name": name,
            "price": float(price)
        }

        if USE_CACHE:
            redis_client.setex(cache_key, 300, json.dumps(product_data))

        return product_data

    return None


def invalidate_product_cache(product_id):
    redis_client.delete(f"product:{product_id}")
    redis_client.delete("products_list")
    redis_client.delete("pc_parts")
    redis_client.delete("orders_report")


# --------------------------------
# INITIALISE DATABASE
# --------------------------------

def init_db():
    conn = get_connection()
    cur = conn.cursor()

    cur.execute("""
        CREATE TABLE IF NOT EXISTS products (
            id SERIAL PRIMARY KEY,
            name TEXT UNIQUE NOT NULL,
            price NUMERIC(10,2) NOT NULL,
            stock INT NOT NULL DEFAULT 0
        );
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS orders (
            id SERIAL PRIMARY KEY,
            email TEXT NOT NULL,
            product_id INT REFERENCES products(id),
            quantity INT,
            build_config JSONB,
            total_price NUMERIC,
            processed_by TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    """)

    cur.execute("CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders(created_at);")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_orders_product_id ON orders(product_id);")

    pc_parts_seed = [
        ("Ryzen 5 7600", 249, 50),
        ("Ryzen 7 7800X", 399, 40),
        ("i5-14600K", 319, 60),
        ("RTX 4060", 329, 30),
        ("RTX 4070", 599, 25),
        ("RTX 4090", 1899, 10),
        ("16GB DDR5", 89, 100),
        ("32GB DDR5", 159, 80),
        ("1TB NVMe", 99, 120),
        ("2TB NVMe", 179, 90),
        ("650W Gold", 109, 75),
        ("850W Gold", 149, 60),
        ("Mid Tower", 99, 50),
        ("Full Tower", 159, 40)
    ]

    for name, price, stock in pc_parts_seed:
        cur.execute("""
            INSERT INTO products (name, price, stock)
            VALUES (%s, %s, %s)
            ON CONFLICT (name) DO NOTHING;
        """, (name, price, stock))

    conn.commit()
    cur.close()
    release_connection(conn)


# --------------------------------
# STARTUP
# --------------------------------

create_new_pool()

try:
    init_db()
except Exception as e:
    print(f"init_db skipped (tables likely already exist): {e}")


# --------------------------------
# ROUTES
# --------------------------------

@app.route("/")
def home():
    return redirect("/build-pc", code=301)


@app.route("/build-pc")
def build_pc():
    return render_template("build.html")


@app.route("/fail")
def fail():
    return jsonify({"error": "forced failure"}), 500


# --------------------------------
# PRODUCTS (CACHED)
# --------------------------------

@app.route("/products")
def get_products():

    cache_key = "products_list"

    cached = None
    if USE_CACHE:
        cached = redis_client.get(cache_key)

    if cached:
        return jsonify(json.loads(cached))

    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    cur.execute("SELECT id, name, price, stock FROM products;")
    products = cur.fetchall()

    cur.close()
    release_connection(conn)

    if USE_CACHE:
        redis_client.setex(cache_key, 300, json.dumps(products))

    return jsonify(products)


# --------------------------------
# PC PARTS (CACHED)
# --------------------------------

@app.route("/pc-parts")
def pc_parts():

    cache_key = "pc_parts"

    cached = None
    if USE_CACHE:
        cached = redis_client.get(cache_key)

    if cached:
        return jsonify(json.loads(cached))

    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    cur.execute("SELECT id, name, price FROM products;")
    rows = cur.fetchall()

    cur.close()
    release_connection(conn)

    grouped = {
        "cpu": [],
        "gpu": [],
        "ram": [],
        "storage": [],
        "psu": [],
        "case": []
    }

    for p in rows:
        name = p["name"]

        if "Ryzen" in name or "i5" in name:
            grouped["cpu"].append(p)
        elif "RTX" in name or "RX" in name:
            grouped["gpu"].append(p)
        elif "DDR5" in name:
            grouped["ram"].append(p)
        elif "NVMe" in name:
            grouped["storage"].append(p)
        elif "Gold" in name:
            grouped["psu"].append(p)
        elif "Tower" in name:
            grouped["case"].append(p)

    if USE_CACHE:
        redis_client.setex(cache_key, 300, json.dumps(grouped, default=float))

    return jsonify(grouped)


# --------------------------------
# SIMPLE ORDER
# --------------------------------

@app.route("/order", methods=["POST"])
def create_order():

    data = request.json or {}
    email = data.get("email")
    product_id = data.get("product_id")
    quantity = int(data.get("quantity", 1))

    if not email or not product_id:
        return jsonify({"error": "Missing required fields"}), 400

    if SIMULATE_BOTTLENECK:
        simulate_stress()
        if should_fail():
            return jsonify({"error": "simulated transient failure"}), 500

    conn = get_connection()
    cur = conn.cursor()

    try:
        cur.execute("BEGIN;")

        cur.execute(
            "SELECT price, stock FROM products WHERE id=%s FOR UPDATE;",
            (product_id,)
        )

        result = cur.fetchone()

        if not result:
            return jsonify({"error": "Product not found"}), 404

        price, stock = result

        if stock < quantity:
            return jsonify({"error": "Not enough stock"}), 400

        total_price = float(price) * quantity

        cur.execute(
            "UPDATE products SET stock = stock - %s WHERE id=%s;",
            (quantity, product_id)
        )

        cur.execute("""
            INSERT INTO orders (email, product_id, quantity, total_price, processed_by)
            VALUES (%s,%s,%s,%s,%s)
            RETURNING id;
        """, (email, product_id, quantity, total_price, POD_NAME))

        order_id = cur.fetchone()[0]

        conn.commit()

        invalidate_product_cache(product_id)

    finally:
        cur.close()
        release_connection(conn)

    return jsonify({
        "order_id": order_id,
        "total_price": total_price,
        "processed_by": POD_NAME
    })


# --------------------------------
# BUILD ORDER
# --------------------------------

@app.route("/build", methods=["POST"])
def create_build():

    data = request.get_json(silent=True)

    if not data:
        return jsonify({"error": "Invalid JSON"}), 400

    email = data.get("email")
    build = data.get("build")

    if not email or not build:
        return jsonify({"error": "Invalid build request"}), 400

    if SIMULATE_BOTTLENECK:
        simulate_stress()
        if should_fail():
            return jsonify({"error": "simulated transient failure"}), 500

    total_price = 0
    selected_parts = {}

    for category, selected_id in build.items():

        product = get_product_by_id(int(selected_id))

        if not product:
            return jsonify({"error": f"Invalid selection in {category}"}), 400

        selected_parts[category] = product
        total_price += product["price"]

    conn = get_connection()
    cur = conn.cursor()

    cur.execute("""
        INSERT INTO orders (email, build_config, total_price, processed_by)
        VALUES (%s,%s,%s,%s)
        RETURNING id;
    """, (email, json.dumps(selected_parts), total_price, POD_NAME))

    order_id = cur.fetchone()[0]

    conn.commit()

    if USE_CACHE:
        redis_client.delete("orders_report")

    # Phase 3: heavy aggregation query — adds DB CPU + connection pressure
    if SIMULATE_BOTTLENECK:
        cur2 = conn.cursor()
        cur2.execute("""
            SELECT product_id, COUNT(*) as order_count
            FROM orders
            GROUP BY product_id
            ORDER BY COUNT(*) DESC;
        """)
        cur2.fetchall()
        cur2.close()

    cur.close()
    release_connection(conn)

    return jsonify({
        "order_id": order_id,
        "total_price": total_price,
        "processed_by": POD_NAME
    })


# --------------------------------
# REPORT (CACHED)
# --------------------------------

@app.route("/report")
def report():

    cache_key = "orders_report"

    cached = None
    if USE_CACHE:
        cached = redis_client.get(cache_key)

    if cached:
        return jsonify(json.loads(cached))

    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    cur.execute("""
        SELECT product_id,
               COUNT(*) as total_orders,
               SUM(total_price) as revenue
        FROM orders
        GROUP BY product_id
        ORDER BY revenue DESC;
    """)

    data = cur.fetchall()

    cur.close()
    release_connection(conn)

    if USE_CACHE:
        redis_client.setex(cache_key, 60, json.dumps(data))

    return jsonify(data)


# --------------------------------
# METRICS
# --------------------------------

@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


# --------------------------------
# HEALTH
# --------------------------------

@app.route("/health")
def health():
    return jsonify({"status": "healthy", "pod": POD_NAME}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
