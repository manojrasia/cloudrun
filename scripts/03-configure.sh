#!/usr/bin/env bash
# README step 3: create terraform.tfvars and backend.hcl from the examples (never overwrites).
source "$(dirname "$0")/lib.sh"
cd "$TF_DIR"
[ -f terraform.tfvars ] || { cp terraform.tfvars.example terraform.tfvars; echo "Created terraform.tfvars - EDIT IT now."; }
[ -f backend.hcl ]      || { cp backend.hcl.example backend.hcl;           echo "Created backend.hcl - set 'bucket' to <PROJECT_ID>-tfstate."; }
echo
echo "Current terraform.tfvars:"; cat terraform.tfvars
echo; echo "Current backend.hcl:";  cat backend.hcl
echo; echo "Edit both files if needed, then run scripts/04-terraform.sh"
