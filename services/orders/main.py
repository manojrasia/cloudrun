import json
import logging
import os
import sys
from uuid import UUID

import psycopg
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, EmailStr, Field


class JsonFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({"severity": record.levelname, "message": record.getMessage()})


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("orders")

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


class Item(BaseModel):
    product_id: int
    quantity: int = Field(ge=1, le=20)


class OrderIn(BaseModel):
    email: EmailStr
    items: list[Item] = Field(min_length=1, max_length=50)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/api/orders", status_code=201)
def create_order(order: OrderIn):
    """Prices come from the database, never from the client. Stock is reserved atomically."""
    wanted: dict[int, int] = {}
    for it in order.items:
        wanted[it.product_id] = wanted.get(it.product_id, 0) + it.quantity

    with db() as conn, conn.transaction():
        total = 0
        currency = "usd"
        priced = []
        for pid, qty in sorted(wanted.items()):
            # Conditional UPDATE: reserve stock only if enough is left.
            r = conn.execute(
                "UPDATE products SET stock = stock - %s "
                "WHERE id = %s AND active AND stock >= %s RETURNING price_cents, currency",
                (qty, pid, qty),
            ).fetchone()
            if not r:
                raise HTTPException(status_code=409, detail=f"product {pid} unavailable or out of stock")
            price, currency = r
            total += price * qty
            priced.append((pid, qty, price))

        order_id = conn.execute(
            "INSERT INTO orders (email, total_cents, currency) VALUES (%s, %s, %s) RETURNING id",
            (order.email, total, currency),
        ).fetchone()[0]
        for pid, qty, price in priced:
            conn.execute(
                "INSERT INTO order_items (order_id, product_id, quantity, unit_price_cents) VALUES (%s, %s, %s, %s)",
                (order_id, pid, qty, price),
            )

    log.info(f"order created order_id={order_id} total_cents={total}")
    return {"order_id": str(order_id), "total_cents": total, "currency": currency}


@app.get("/api/orders/{order_id}")
def get_order(order_id: UUID):
    with db() as conn:
        r = conn.execute(
            "SELECT status, total_cents, currency, created_at FROM orders WHERE id = %s", (order_id,)
        ).fetchone()
        if not r:
            raise HTTPException(status_code=404, detail="order not found")
        items = conn.execute(
            "SELECT p.name, i.quantity, i.unit_price_cents FROM order_items i "
            "JOIN products p ON p.id = i.product_id WHERE i.order_id = %s",
            (order_id,),
        ).fetchall()
    return {
        "order_id": str(order_id),
        "status": r[0],
        "total_cents": r[1],
        "currency": r[2],
        "created_at": r[3].isoformat(),
        "items": [{"name": n, "quantity": q, "unit_price_cents": p} for n, q, p in items],
    }
