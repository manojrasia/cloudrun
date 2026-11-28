#!/usr/bin/env bash
# README step 4: create the infrastructure (init, plan, apply).
# Usage: scripts/04-terraform.sh [-y]   (-y skips the apply confirmation)
source "$(dirname "$0")/lib.sh"; need terraform; load_config
cd "$TF_DIR"
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
if [ "${1:-}" = "-y" ]; then
  terraform apply tfplan
else
  read -r -p "Apply this plan? (takes 15-25 min the first time) [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] && terraform apply tfplan || { echo "Cancelled."; exit 1; }
fi
rm -f tfplan
echo "Step 4 done. If an API was not ready yet, wait a minute and run this script again."
