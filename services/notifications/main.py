import base64
import json
import logging
import os
import sys
import urllib.request

from fastapi import FastAPI, HTTPException, Request, Response


class JsonFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({"severity": record.levelname, "message": record.getMessage()})


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("notifications")

app = FastAPI(docs_url=None, redoc_url=None)
API_KEY = os.environ.get("EMAIL_API_KEY", "REPLACE_ME")
FROM = os.environ.get("EMAIL_FROM", "orders@example.com")
SHOP = os.environ.get("SHOP_NAME", "Shop")


def send_email(to: str, subject: str, text: str):
    """SendGrid v3 API. With the placeholder key, only logs, so the pipeline works before email is set up."""
    if API_KEY == "REPLACE_ME":
        log.warning(f"EMAIL_API_KEY not configured; would send '{subject}' to a customer")
        return
    body = json.dumps({
        "personalizations": [{"to": [{"email": to}]}],
        "from": {"email": FROM, "name": SHOP},
        "subject": subject,
        "content": [{"type": "text/plain", "value": text}],
    }).encode()
    req = urllib.request.Request(
        "https://api.sendgrid.com/v3/mail/send",
        data=body,
        headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"},
    )
    urllib.request.urlopen(req, timeout=10).read()


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/pubsub/push")
async def push(request: Request):
    """Pub/Sub push handler (Cloud Run IAM already verified the OIDC token).

    Non-2xx => retry with backoff, then dead-letter after 5 attempts. Delivery is at-least-once,
    so a customer can very rarely get a duplicate email.
    """
    envelope = await request.json()
    msg = envelope.get("message")
    if not msg:
        raise HTTPException(status_code=400, detail="bad envelope")
    try:
        event = json.loads(base64.b64decode(msg["data"]))
    except Exception:
        log.error(f"undecodable message message_id={msg.get('messageId')}")
        return Response(status_code=204)  # poison message: ack so it doesn't loop

    if event.get("type") == "order.paid":
        total = f"{event['total_cents'] / 100:.2f} {event['currency'].upper()}"
        send_email(
            event["email"],
            f"Your {SHOP} order is confirmed",
            f"Thanks for your order!\n\nOrder: {event['order_id']}\nTotal: {total}\n",
        )
        log.info(f"confirmation handled order_id={event['order_id']}")
    return Response(status_code=204)
