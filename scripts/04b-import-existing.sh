#!/usr/bin/env bash
# Fixes "Error 409: ... already exists" on terraform apply.
# Cause: the resources exist in GCP (from an earlier run) but are missing from Terraform state
# (state was lost, or an older run used a different backend prefix). This imports them into state.
# Safe to re-run: anything already in state, or not existing in GCP, is skipped.
source "$(dirname "$0")/lib.sh"; need terraform; need gcloud; load_config
cd "$TF_DIR"
terraform init -backend-config=backend.hcl -input=false >/dev/null

P="$PROJECT_ID"
CERT_HASH=$(printf %s "$DOMAIN" | md5sum | cut -c1-6)   # same as substr(md5(var.domain), 0, 6) in lb.tf
POOL="projects/$P/locations/global/workloadIdentityPools/$PREFIX-gh"

IN_STATE=$(terraform state list 2>/dev/null || true)
imp() {  # imp <address> <id>
  if grep -qxF "$1" <<<"$IN_STATE"; then echo "in state already: $1"; return; fi
  echo "importing $1"
  terraform import -input=false "$1" "$2" >/dev/null 2>&1 \
    && echo "  ok" || echo "  skipped (does not exist in GCP, or already handled)"
}

imp google_iam_workload_identity_pool.github          "$POOL"
imp google_iam_workload_identity_pool_provider.github "$POOL/providers/github"
imp google_service_account.pubsub_invoker             "projects/$P/serviceAccounts/$PREFIX-psub-invoker@$P.iam.gserviceaccount.com"
imp google_service_account.deployer                   "projects/$P/serviceAccounts/$PREFIX-deployer@$P.iam.gserviceaccount.com"
imp google_compute_managed_ssl_certificate.cert       "projects/$P/global/sslCertificates/$APP-$ENV-cert-$CERT_HASH"

echo
echo "State now holds $(terraform state list | wc -l) resources. Run scripts/04-terraform.sh again."
echo "If the workload identity pool import is skipped but apply still says 409, the pool was deleted"
echo "within the last 30 days (GCP soft-deletes it). Restore it with:"
echo "  gcloud iam workload-identity-pools undelete $PREFIX-gh --project $P --location global"
echo "then run this script again."
