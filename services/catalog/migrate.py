"""Idempotent schema + seed for the whole shop. Runs as a Cloud Run Job before each deploy."""
import os

import psycopg

SCHEMA = [
    """
    CREATE TABLE IF NOT EXISTS products (
        id          SERIAL PRIMARY KEY,
        sku         TEXT UNIQUE NOT NULL,
        name        TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        price_cents INTEGER NOT NULL CHECK (price_cents >= 0),
        currency    TEXT NOT NULL DEFAULT 'usd',
        image_url   TEXT NOT NULL DEFAULT '',
        stock       INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0),
        active      BOOLEAN NOT NULL DEFAULT TRUE
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS orders (
        id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        email                    TEXT NOT NULL,
        status                   TEXT NOT NULL DEFAULT 'pending'
                                 CHECK (status IN ('pending', 'paid', 'cancelled')),
        total_cents              INTEGER NOT NULL,
        currency                 TEXT NOT NULL,
        payment_ref              TEXT,
        created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
        paid_at                  TIMESTAMPTZ
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS order_items (
        order_id         UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
        product_id       INTEGER NOT NULL REFERENCES products(id),
        quantity         INTEGER NOT NULL CHECK (quantity > 0),
        unit_price_cents INTEGER NOT NULL,
        PRIMARY KEY (order_id, product_id)
    )
    """,
    # Databases created before the dummy payment provider had a differently named payment column.
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS payment_ref TEXT",
    "CREATE INDEX IF NOT EXISTS orders_status_created ON orders (status, created_at)",
]

SEED = [
    ("TEE-001", "Classic tee", "Soft organic cotton t-shirt.", 2500, "/images/tee.jpg", 100),
    ("MUG-001", "Stoneware mug", "350 ml, dishwasher safe.", 1800, "/images/mug.jpg", 60),
    ("BAG-001", "Canvas tote", "Heavy-duty everyday tote.", 2200, "/images/tote.jpg", 80),
    ("CAP-001", "Dad cap", "Adjustable, washed cotton.", 2000, "/images/cap.jpg", 50),
    ("NTB-001", "Dot-grid notebook", "A5, 120 pages.", 1200, "/images/notebook.jpg", 120),
    ("STK-001", "Sticker pack", "Set of 10 vinyl stickers.", 800, "/images/stickers.jpg", 300),
]

with psycopg.connect(
    host=os.environ["DB_HOST"],
    dbname=os.environ["DB_NAME"],
    user=os.environ["DB_USER"],
    password=os.environ["DB_PASSWORD"],
    sslmode="require",
) as conn:
    for sql in SCHEMA:
        conn.execute(sql)
    # Seed demo products only on an empty catalog.
    if conn.execute("SELECT count(*) FROM products").fetchone()[0] == 0:
        for sku, name, desc, price, img, stock in SEED:
            conn.execute(
                "INSERT INTO products (sku, name, description, price_cents, image_url, stock) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                (sku, name, desc, price, img, stock),
            )
print("migrations applied")
