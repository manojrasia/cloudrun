#!/usr/bin/env bash
# README step 2: create the versioned bucket that holds Terraform state.
source "$(dirname "$0")/lib.sh"; need gcloud; load_config
if gcloud storage buckets describe "gs://$STATE_BUCKET" >/dev/null 2>&1; then
  echo "Bucket gs://$STATE_BUCKET already exists, skipping create."
else
  gcloud storage buckets create "gs://$STATE_BUCKET" --project "$PROJECT_ID" --location="$REGION" --uniform-bucket-level-access
fi
gcloud storage buckets update "gs://$STATE_BUCKET" --versioning
echo "Step 2 done."
