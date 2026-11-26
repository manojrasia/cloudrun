import json
import logging
import os
import sys
from uuid import UUID

import psycopg
import stripe
from fastapi import FastAPI, HTTPException, Request
from google.cloud import pubsub_v1
from pydantic import BaseModel


class JsonFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({"severity": record.levelname, "message": record.getMessage()})


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("payments")

app = FastAPI(docs_url=None, redoc_url=None)
stripe.api_key = os.environ.get("STRIPE_SECRET_KEY", "")
WEBHOOK_SECRET = os.environ.get("STRIPE_WEBHOOK_SECRET", "")
PUBLISHABLE_KEY = os.environ.get("STRIPE_PUBLISHABLE_KEY", "")
TOPIC = os.environ.get("PUBSUB_TOPIC", "")
publisher = pubsub_v1.PublisherClient()


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


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/api/payments/intent")
def create_intent(body: IntentIn):
    """Create a Stripe PaymentIntent for a pending order. The amount comes from the database."""
    with db() as conn:
        r = conn.execute(
            "SELECT total_cents, currency, status, stripe_payment_intent_id FROM orders WHERE id = %s",
            (body.order_id,),
        ).fetchone()
        if not r:
            raise HTTPException(status_code=404, detail="order not found")
        total, currency, status, existing = r
        if status != "pending":
            raise HTTPException(status_code=409, detail=f"order is {status}")

        # Reuse the intent if the customer retries checkout.
        if existing:
            intent = stripe.PaymentIntent.retrieve(existing)
        else:
            intent = stripe.PaymentIntent.create(
                amount=total,
                currency=currency,
                automatic_payment_methods={"enabled": True},
                metadata={"order_id": str(body.order_id)},
                idempotency_key=f"order-{body.order_id}",
            )
            conn.execute(
                "UPDATE orders SET stripe_payment_intent_id = %s WHERE id = %s", (intent.id, body.order_id)
            )
    return {"client_secret": intent.client_secret, "publishable_key": PUBLISHABLE_KEY}


@app.post("/api/payments/webhook")
async def webhook(request: Request):
    """Stripe -> us. The signature check is the only authentication, so it is mandatory."""
    payload = await request.body()
    sig = request.headers.get("stripe-signature", "")
    try:
        event = stripe.Webhook.construct_event(payload, sig, WEBHOOK_SECRET)
    except (ValueError, stripe.SignatureVerificationError):
        raise HTTPException(status_code=400, detail="invalid signature")

    if event["type"] == "payment_intent.succeeded":
        intent = event["data"]["object"]
        order_id = intent["metadata"].get("order_id")
        if order_id:
            with db() as conn:
                # Only the first delivery flips pending -> paid, so events publish exactly once per order.
                r = conn.execute(
                    "UPDATE orders SET status = 'paid', paid_at = now() "
                    "WHERE id = %s AND status = 'pending' RETURNING email, total_cents, currency",
                    (order_id,),
                ).fetchone()
            if r:
                msg = {"type": "order.paid", "order_id": order_id, "email": r[0], "total_cents": r[1], "currency": r[2]}
                publisher.publish(TOPIC, json.dumps(msg).encode()).result(timeout=10)
                log.info(f"order paid order_id={order_id}")
    return {"received": True}
