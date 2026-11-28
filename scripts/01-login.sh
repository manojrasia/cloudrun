#!/usr/bin/env bash
# README step 1: log in and pick your project.
# Usage: scripts/01-login.sh [PROJECT_ID]   (PROJECT_ID defaults to terraform.tfvars)
source "$(dirname "$0")/lib.sh"
need gcloud
PROJECT_ID="${1:-$(tfvar project_id)}"
[ -n "$PROJECT_ID" ] || { echo "Usage: $0 PROJECT_ID"; exit 1; }
gcloud auth login
gcloud auth application-default login
gcloud config set project "$PROJECT_ID"
gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com
echo "Step 1 done."
