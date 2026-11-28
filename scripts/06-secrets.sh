#!/usr/bin/env bash
# README step 6: store the optional email (SendGrid) key. Payments are a built-in dummy now,
# so there are no payment keys and no webhook to register.
# Usage: SENDGRID_API_KEY=SG.xxx scripts/06-secrets.sh     (or pass the key as $1)
source "$(dirname "$0")/lib.sh"; need gcloud; load_config
KEY="${1:-${SENDGRID_API_KEY:-}}"
if [ -z "$KEY" ]; then
  echo "No email key given - skipping. 'notifications' will only log that it would have sent a receipt."
  exit 0
fi
printf %s "$KEY" | gcloud secrets versions add "$PREFIX-email-api-key" --project "$PROJECT_ID" --data-file=-
echo "Step 6 done. Re-run the deploy workflow (step 8) so services pick up the new secret."
