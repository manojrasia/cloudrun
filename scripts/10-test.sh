#!/usr/bin/env bash
# README step 10: end-to-end test against the live site with the dummy payment, then read the logs.
source "$(dirname "$0")/lib.sh"; need curl; need python3; load_config
BASE="https://$DOMAIN"
CURL="curl -sS --fail-with-body"
jget() { python3 -c "import sys,json; print(json.load(sys.stdin)$1)"; }

echo "1. Products"
PID=$($CURL "$BASE/api/products" | jget "[0]['id']"); echo "   first product id: $PID"

echo "2. Create order"
ORDER=$($CURL -X POST "$BASE/api/orders" -H 'content-type: application/json' \
  -d "{\"email\":\"test@example.com\",\"items\":[{\"product_id\":$PID,\"quantity\":1}]}")
OID=$(echo "$ORDER" | jget "['order_id']"); echo "   order: $OID"

echo "3. Create payment"
PAY=$($CURL -X POST "$BASE/api/payments/intent" -H 'content-type: application/json' -d "{\"order_id\":\"$OID\"}" | jget "['payment_id']")

echo "4. Declined card should fail (402)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/payments/confirm" -H 'content-type: application/json' \
  -d "{\"order_id\":\"$OID\",\"payment_id\":\"$PAY\",\"card_number\":\"4000000000000002\"}")
[ "$CODE" = "402" ] && echo "   got 402 as expected" || { echo "   expected 402, got $CODE"; exit 1; }

echo "5. Pay with 4242 4242 4242 4242"
$CURL -X POST "$BASE/api/payments/confirm" -H 'content-type: application/json' \
  -d "{\"order_id\":\"$OID\",\"payment_id\":\"$PAY\",\"card_number\":\"4242424242424242\"}"; echo

echo "6. Order status"
STATUS=$($CURL "$BASE/api/orders/$OID" | jget "['status']"); echo "   status: $STATUS"
[ "$STATUS" = "paid" ] || { echo "FAILED: order is not paid"; exit 1; }

if command -v gcloud >/dev/null 2>&1; then
  echo "7. Logs"
  for s in payments notifications; do
    echo "--- $PREFIX-$s"
    gcloud run services logs read "$PREFIX-$s" --project "$PROJECT_ID" --region "$REGION" --limit 10 || true
  done
fi
echo "PASS. Open $BASE in a browser for the visual check."
