import json
import logging
import os
import sys
from uuid import UUID, uuid4

import psycopg
from fastapi import FastAPI, HTTPException
from google.cloud import pubsub_v1
from pydantic import BaseModel, Field


class JsonFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({"severity": record.levelname, "message": record.getMessage()})


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("payments")

app = FastAPI(docs_url=None, redoc_url=None)
TOPIC = os.environ.get("PUBSUB_TOPIC", "")
publisher = pubsub_v1.PublisherClient()

# Dummy payment provider. No real money moves and no external service is called.
# The outcome is decided by the test card number, like a real provider's test mode.
TEST_CARDS = {
    "4242424242424242": ("succeeded", None),
    "4000000000000002": ("declined", "Your card was declined."),
    "4000000000009995": ("declined", "Your card has insufficient funds."),
}


def db():
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        sslmode="require",
        connect_timeout=5,
    )


class IntentIn(BaseModel):
    order_id: UUID


class ConfirmIn(BaseModel):
    order_id: UUID
    payment_id: str = Field(min_length=1, max_length=100)
    card_number: str = Field(min_length=12, max_length=23)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/api/payments/intent")
def create_intent(body: IntentIn):
    """Create a dummy payment for a pending order. The amount comes from the database."""
    with db() as conn:
        r = conn.execute(
            "SELECT total_cents, currency, status, payment_ref FROM orders WHERE id = %s",
            (body.order_id,),
        ).fetchone()
        if not r:
            raise HTTPException(status_code=404, detail="order not found")
        total, currency, status, existing = r
        if status != "pending":
            raise HTTPException(status_code=409, detail=f"order is {status}")

        # Reuse the payment if the customer retries checkout.
        payment_id = existing or f"dummy_{uuid4().hex}"
        if not existing:
            conn.execute("UPDATE orders SET payment_ref = %s WHERE id = %s", (payment_id, body.order_id))
    return {"payment_id": payment_id, "amount_cents": total, "currency": currency}


@app.post("/api/payments/confirm")
def confirm(body: ConfirmIn):
    """Dummy 'charge'. Only test cards are accepted. The first success flips the order to paid."""
    card = "".join(ch for ch in body.card_number if ch.isdigit())
    outcome, reason = TEST_CARDS.get(card, ("declined", "Use a test card, for example 4242 4242 4242 4242."))

    with db() as conn:
        r = conn.execute("SELECT status, payment_ref FROM orders WHERE id = %s", (body.order_id,)).fetchone()
        if not r:
            raise HTTPException(status_code=404, detail="order not found")
        status, payment_ref = r
        if status == "paid":
            return {"status": "paid"}  # idempotent: a double click must not publish twice
        if status != "pending":
            raise HTTPException(status_code=409, detail=f"order is {status}")
        if payment_ref != body.payment_id:
            raise HTTPException(status_code=400, detail="payment does not belong to this order")

        if outcome != "succeeded":
            log.info(f"payment declined order_id={body.order_id} last4={card[-4:]}")
            raise HTTPException(status_code=402, detail=reason)

        # Only the first call flips pending -> paid, so events publish exactly once per order.
        row = conn.execute(
            "UPDATE orders SET status = 'paid', paid_at = now() "
            "WHERE id = %s AND status = 'pending' RETURNING email, total_cents, currency",
            (body.order_id,),
        ).fetchone()

    if row:
        msg = {"type": "order.paid", "order_id": str(body.order_id), "email": row[0], "total_cents": row[1], "currency": row[2]}
        publisher.publish(TOPIC, json.dumps(msg).encode()).result(timeout=10)
        log.info(f"order paid order_id={body.order_id}")
    return {"status": "paid"}
