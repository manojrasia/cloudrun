#!/usr/bin/env bash
# README step 5: show the load balancer IP and the certificate status.
# Use --wait to poll until the certificate is ACTIVE.
source "$(dirname "$0")/lib.sh"; need terraform; need gcloud; load_config
IP=$(cd "$TF_DIR" && terraform output -raw lb_ip)
echo "Load balancer IP: $IP"
echo "Create a DNS A record:  $DOMAIN -> $IP   (not needed for sslip.io / nip.io hostnames)"
status() {
  # The certificate name carries a hash suffix, so list by domain.
  gcloud compute ssl-certificates list --project "$PROJECT_ID" \
    --filter="managed.domains:$DOMAIN" --format="value(name,managed.status)"
}
status
if [ "${1:-}" = "--wait" ]; then
  until status | grep -q ACTIVE; do echo "Waiting for certificate (60s)..."; sleep 60; done
  echo "Certificate is ACTIVE."
fi
