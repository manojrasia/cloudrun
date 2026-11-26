import json
import logging
import os
import sys

import psycopg
from fastapi import FastAPI, HTTPException


class JsonFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({"severity": record.levelname, "message": record.getMessage()})


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])

app = FastAPI(docs_url=None, redoc_url=None)


def db():
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        sslmode="require",
        connect_timeout=5,
    )


COLS = "id, sku, name, description, price_cents, currency, image_url, stock"


def row(r):
    return dict(zip(["id", "sku", "name", "description", "price_cents", "currency", "image_url", "stock"], r))


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/api/products")
def list_products():
    with db() as conn:
        rows = conn.execute(f"SELECT {COLS} FROM products WHERE active ORDER BY id").fetchall()
    return [row(r) for r in rows]


@app.get("/api/products/{product_id}")
def get_product(product_id: int):
    with db() as conn:
        r = conn.execute(f"SELECT {COLS} FROM products WHERE id = %s AND active", (product_id,)).fetchone()
    if not r:
        raise HTTPException(status_code=404, detail="product not found")
    return row(r)
